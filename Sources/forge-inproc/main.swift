import Foundation
import ForgeCore
import MLXServeCore
import MLXToolKit

// The golden output for the plugin: one model run in-process through ForgeCore's own ForgeEngineService, registered
// exactly as ForgeCore registers it, with the request the worker builds for the same call. Writes the output (an image,
// or a matte) to --out and prints one JSON line with timings and the measured footprint (a score's value too). The
// generative stills tiers (upscaleGenerative, upscaleNacre) run behind ForgeCore's text guard, through
// `EngineImageEnhancer`, as pixel-agency-image-engine runs them. Not part of the plugin bundle.
//
//   forge-inproc --model <ForgeModel> --image <png> [--mask <png>] [--mode fast] [--scale 2] [--kind softAlpha|binary]
//                [--points x,y;x,y] [--labels 1,0] [--strength s] [--threshold t] [--models-root <dir>] --out <png>
//                [--repeat N] [--sink]
//
// --repeat runs the call N times after the first and prints each run's seconds (warm times); --sink binds a RunProgress
// sink that encodes every report as a JSON line to /dev/null, as a plugin worker relays each one over GPP.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func physFootprint() -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? info.ri_phys_footprint : 0
}
func image(_ path: String) throws -> Image {
    Image(format: path.lowercased().hasSuffix(".png") ? .png : .jpeg, data: try Data(contentsOf: URL(fileURLWithPath: path)))
}

guard let name = option("--model"), let model = ForgeModel(rawValue: name), let imagePath = option("--image"),
      let outPath = option("--out") else {
    FileHandle.standardError.write(Data("usage: forge-inproc --model <ForgeModel> --image <png> --out <png> [options]\n".utf8))
    exit(2)
}
let repeats = option("--repeat").flatMap(Int.init) ?? 0
let bindSink = args.contains("--sink")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

let started = ContinuousClock.now
let service = ForgeEngineService()
_ = await service.attachModelStore(root: modelsRoot)
await service.registerAll()
guard let id = service.packageID(for: model) else {
    FileHandle.standardError.write(Data("\(name) didn't register: \(service.outcome(for: model)?.failure ?? "?")\n".utf8))
    exit(1)
}

let input = try image(imagePath)
let mode = option("--mode").map { Mode(rawValue: $0) }
let request: any CapabilityRequest
switch model.capability {
case .imageInpaint:
    request = InpaintRequest(image: input, mask: try image(option("--mask") ?? ""), mode: mode)
case .imageUpscale:
    request = ImageUpscaleRequest(image: input, scale: option("--scale").flatMap(Int.init))
case .matting:
    request = MattingRequest(image: input, preferredKind: option("--kind").flatMap(Matte.Kind.init(rawValue:)) ?? .softAlpha)
case .promptSegment:
    let points = (option("--points") ?? "").split(separator: ";").map { $0.split(separator: ",").compactMap { Float($0) } }
    let labels = (option("--labels") ?? "").split(separator: ",").compactMap { Int($0) }
    request = PromptSegmentRequest(image: input, points: points, pointLabels: labels.isEmpty ? points.map { _ in 1 } : labels)
case .imageRestore:
    request = ImageRestoreRequest(image: input, strength: option("--strength").flatMap(Float.init))
case .imageRelight:
    request = ImageRelightRequest(image: input, strength: option("--strength").flatMap(Float.init))
case .imageColorize:
    request = ColorizeRequest(image: input)
case .imageQualityScore:
    request = ImageQualityScoreRequest(image: input)
case .defectDetect:
    request = DefectDetectRequest(image: input, preferredKind: option("--kind") == "softAlpha" ? .softAlpha : .binary,
                                  threshold: option("--threshold").flatMap(Float.init))
default:
    FileHandle.standardError.write(Data("forge-inproc doesn't drive \(model.capability) yet\n".utf8))
    exit(2)
}

var clock = ContinuousClock.now
_ = try await service.engine.prepare(model.capability, package: id)
let prepare = seconds(since: clock)
let devNull = FileHandle(forWritingAtPath: "/dev/null")!
let sink: RunProgress.Sink = { report in
    let line: [String: Any] = ["type": "progress", "stage": report.phase.rawValue, "step": report.step ?? 0, "of": report.totalSteps ?? 0]
    devNull.write((try? JSONSerialization.data(withJSONObject: line)) ?? Data())
}
var ran: String?
func call() async throws -> any CapabilityResponse {
    if [.upscaleGenerative, .upscaleNacre].contains(model), let upscale = request as? ImageUpscaleRequest {
        // pixel-agency-image-engine's route for a generative stills tier: the enhancer, behind the text guard.
        let enhancer = await EngineImageEnhancer(service: service)
        let outcome = try await enhancer.upscaleReporting(try EngineImageCoding.cgImage(from: upscale.image),
                                                          factor: upscale.scale == 2 ? .x2 : .x4,
                                                          tier: model == .upscaleNacre ? .generativeClean : .generative)
        ran = outcome.upscaleModel
        return ImageUpscaleResponse(image: try EngineImageCoding.pngImage(from: outcome.image), appliedScale: upscale.scale ?? 4)
    }
    return try await service.engine.run(request, package: id)
}
func timedCall() async throws -> (any CapabilityResponse, Double) {
    let start = ContinuousClock.now
    let r = bindSink ? try await RunProgress.$sink.withValue(sink) { try await call() } : try await call()
    return (r, seconds(since: start))
}
let (response, run) = try await timedCall()
var warm: [Double] = []
for _ in 0..<repeats { warm.append(try await timedCall().1) }

var data = Data()
var result: [String: Any] = ["model": name, "package": id.rawValue, "prepare_s": prepare, "run_s": run,
                             "total_s": seconds(since: started), "phys_footprint": physFootprint()]
if let ran { result["upscale_model"] = ran }
if !warm.isEmpty { result["warm_s"] = warm }
switch response {
case let r as InpaintResponse: data = r.image.data
case let r as ImageUpscaleResponse: data = r.image.data; result["applied_scale"] = r.appliedScale
case let r as MattingResponse: data = r.matte.data
case let r as PromptSegmentResponse: data = r.matte.data; result["score"] = Double(r.score)
case let r as ImageRestoreResponse: data = r.image.data
case let r as ImageRelightResponse: data = r.image.data; result["bypassed"] = r.bypassed
case let r as ColorizeResponse: data = r.image.data
case let r as DefectDetectResponse: data = r.mask.data
// The Float's own digits, as JSONEncoder writes it over GPP.
case let r as ImageQualityScoreResponse: result["score"] = r.score.description; result["subscores"] = r.subscores.mapValues(\.description)
default: FileHandle.standardError.write(Data("unexpected response \(type(of: response))\n".utf8)); exit(1)
}
if !data.isEmpty { try data.write(to: URL(fileURLWithPath: outPath)) }
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))

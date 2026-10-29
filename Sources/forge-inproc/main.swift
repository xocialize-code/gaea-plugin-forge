import Foundation
import ForgeCore
import MLXServeCore
import MLXToolKit

// The golden output for the plugin: one model run in-process through ForgeCore's own ForgeEngineService, registered
// exactly as ForgeCore registers it, with the request the worker builds for the same call. Writes the output (an image,
// or a matte) to --out and prints one JSON line with timings and the measured footprint. Not part of the plugin bundle.
//
//   forge-inproc --model inpaint|upscale|matte|promptMask|restore --image <png> [--mask <png>] [--mode fast]
//                [--scale 2] [--kind softAlpha|binary] [--points x,y;x,y] [--labels 1,0] [--strength s]
//                [--models-root <dir>] --out <png>

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
default:
    FileHandle.standardError.write(Data("forge-inproc doesn't drive \(model.capability) yet\n".utf8))
    exit(2)
}

var clock = ContinuousClock.now
_ = try await service.engine.prepare(model.capability, package: id)
let prepare = seconds(since: clock)
clock = ContinuousClock.now
let response = try await service.engine.run(request, package: id)
let run = seconds(since: clock)

let data: Data
var result: [String: Any] = ["model": name, "package": id.rawValue, "prepare_s": prepare, "run_s": run,
                             "total_s": seconds(since: started), "phys_footprint": physFootprint()]
switch response {
case let r as InpaintResponse: data = r.image.data
case let r as ImageUpscaleResponse: data = r.image.data; result["applied_scale"] = r.appliedScale
case let r as MattingResponse: data = r.matte.data
case let r as PromptSegmentResponse: data = r.matte.data; result["score"] = Double(r.score)
case let r as ImageRestoreResponse: data = r.image.data
default: FileHandle.standardError.write(Data("unexpected response \(type(of: response))\n".utf8)); exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))

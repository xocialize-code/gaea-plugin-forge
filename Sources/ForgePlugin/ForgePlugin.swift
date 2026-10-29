import CoreGraphics
import ForgeCore
import Foundation
import GaeaPluginKit
import GaeaProtocol
import MaskKit
import MLX
import MLXBiRefNet
import MLXBOPBTL
import MLXCIDNet
import MLXDDColor
import MLXDRUNet
import MLXEdgeTAM
import MLXGFPGAN
import MLXHEART
import MLXInpaint
import MLXNacre
import MLXNAFNet
import MLXNERVE
import MLXRealPLKSR
import MLXRestoreFormer
import MLXRestormer
import MLXSCUNet
import MLXSigLIP2IQA
import MLXToolKit
import MLXVOSR

// gaea-plugin-forge: the processing pack (Gaea AB-T-0369). ForgeCore's image models in one process, since a worker
// costs ~146 MB and these models are small: each registered in the configuration ForgeCore's ForgeEngineService
// registers it with, under mlx-image-runtime's catalog id, so the image normalizer's operation table finds it.
//
// Gaea's image normalizer composes them: it calls each model as the plugin's offer of that capability's operation and
// applies the Image profile's rules (exact scale, black-mask pixels kept, alpha, sizes). The worker maps one call onto
// the engine: inpaint (LaMa, or MI-GAN as its `fast` mode), upscale (NERVE, RealPLKSR, HEART), matte (BiRefNet),
// segment (EdgeTAM, SAM 2.1) and restore (NAFNet, Restormer's three variants, DRUNet, SCUNet, GFPGAN, RestoreFormer++).
// Since 0.2.0 (AB-T-0377) also relight (HVI-CIDNet), colorize (DDColor), score (SigLIP2 IQA), the upscalers Anime4K VL,
// VOSR2 and Nacre, and BOPBTL's defect detection as a helper Gaea calls for restore's scratches. Weights come from the
// models root Gaea sends in configure, or the package itself; the engine materializes what's missing.

/// A model the pack registers: its package, its configuration as ForgeCore registers it, and what it serves.
struct ForgeEntry: Sendable {
    var model: ModelDefinition
    var offer: PluginManifest.Offer
}

/// The licence an offer states, from the package's own manifest (its weights' licence).
func license(_ manifest: PackageManifest) -> JSONValue {
    let weights = manifest.license.weightLicense
    var license: [String: JSONValue] = ["spdx": .string(weights.identifier), "commercial_use": .bool(weights.isPermissive)]
    if let notice = weights.requiredDisplayText { license["notice"] = .string(notice) }
    return .object(license)
}

/// One model of the pack: one lane, named after the quant it resolves to (GPP-1 §4.7), serving one MES operation.
func entry<P: ModelPackage>(_ package: P.Type, _ configuration: P.Configuration, id: String, title: String,
                            operation: EngineOperation, speed: String, memory: String = "small", notes: String,
                            maxPixels: Int) -> ForgeEntry {
    ForgeEntry(
        model: model(package, configuration, id: id, title: title, operations: [operation]),
        offer: offer(operation.operation, id: id, title: title, manifest: P.manifest, speed: speed, memory: memory, notes: notes,
                     maxPixels: maxPixels))
}

/// The model of one entry: one lane, named after the quant it resolves to.
func model<P: ModelPackage>(_ package: P.Type, _ configuration: P.Configuration, id: String, title: String,
                            operations: [EngineOperation]) -> ModelDefinition {
    let resolved = ResolvedLane(manifest: P.manifest, configuration: configuration)
    let lane = resolved.quant?.rawValue ?? resolved.footprintQuant?.rawValue ?? "default"
    return .engine(package, id: id, title: title, lanes: [LaneDefinition(id: lane, default: true, configuration: configuration)],
                   operations: operations)
}

func offer(_ operation: String, id: String, title: String, manifest: PackageManifest, speed: String, memory: String = "small",
           notes: String, maxPixels: Int) -> PluginManifest.Offer {
    PluginManifest.Offer(
        operation: operation, profile: "image",
        model: ["id": .string(id), "title": .string(title), "license": license(manifest), "memory_class": .string(memory),
                "speed_class": .string(speed), "quality_tiers": ["draft", "standard", "best"], "notes": .string(notes)],
        limits: PluginManifest.Limits(maxPixels: maxPixels, sizeMultiple: 1, maxImages: 1))
}

// MARK: - Operations: one engine call each, with what the normalizer passes

/// Inpaint: `image` and `mask` (white = remove). `mode` `fast` is MI-GAN; otherwise LaMa.
let fill = EngineOperation("image.fill", outputNames: ["image": "image"]) { job in
    let mode = job.param("mode")?.stringValue.flatMap { $0.isEmpty ? nil : Mode(rawValue: $0) }
    return EngineCall(InpaintRequest(image: try job.image("image"), mask: try job.image("mask"), mode: mode),
                      effective: ["mode": .string(mode?.rawValue ?? InpaintContract.best.rawValue)])
}

/// Upscale by `scale` (the package's native ×2 and ×4; it says what ran in `applied_scale`).
let upscale = EngineOperation("image.upscale", outputNames: ["image": "image"]) { job in
    let scale = job.param("scale")?.intValue
    return EngineCall(ImageUpscaleRequest(image: try job.image("image"), scale: scale),
                      effective: scale.map { ["scale": .int(Int64($0))] } ?? [:])
}

/// A matte of the foreground: `kind` `softAlpha` (default) or `binary`, as a grey PNG `mask`.
let matte = EngineOperation("image.matte", outputNames: ["matte": "mask"]) { job in
    let kind = job.param("kind")?.stringValue.flatMap(Matte.Kind.init(rawValue:)) ?? .softAlpha
    return EngineCall(MattingRequest(image: try job.image("image"), preferredKind: kind), effective: ["kind": .string(kind.rawValue)])
}

/// A mask of the object at `points` ([[x, y]] in pixels) with `pointLabels` (1 inside, 0 outside), or a `box`; the
/// model's `score` comes back as a value.
let segment = EngineOperation("image.segment", outputNames: ["matte": "masks"]) { job in
    let points = (job.param("points")?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap { $0.doubleValue.map(Float.init) } }
    let labels = (job.param("pointLabels")?.arrayValue ?? []).compactMap(\.intValue)
    let box = job.param("box")?.arrayValue?.compactMap { $0.doubleValue.map(Float.init) }
    guard !points.isEmpty || box != nil else {
        throw GPPError(.invalidRequest, "image.segment needs points or a box.")
    }
    guard labels.isEmpty || labels.count == points.count else {
        throw GPPError(.invalidRequest, "pointLabels needs one label per point.")
    }
    return EngineCall(PromptSegmentRequest(image: try job.image("image"), points: points,
                                           pointLabels: labels.isEmpty ? Array(repeating: 1, count: points.count) : labels,
                                           box: box))
}

/// Restore, at `strength` when the model takes one.
let restore = EngineOperation("image.restore", outputNames: ["image": "image"]) { job in
    let strength = job.param("strength")?.doubleValue.map(Float.init)
    return EngineCall(ImageRestoreRequest(image: try job.image("image"), strength: strength))
}

/// Relight: exposure correction at `strength` (nil: the package's full strength). A correctly exposed input comes back
/// as it was (`bypassed`): CIDNet's luma gate is in the package.
let relight = EngineOperation("image.relight", outputNames: ["image": "image"]) { job in
    let strength = job.param("strength")?.doubleValue.map(Float.init)
    return EngineCall(ImageRelightRequest(image: try job.image("image"), strength: strength))
}

/// Colorize a black-and-white photo.
let colorize = EngineOperation("image.colorize", outputNames: ["image": "image"]) { job in
    EngineCall(ColorizeRequest(image: try job.image("image")))
}

/// A no-reference quality score in 0…1, with the model's subscores, as values.
let score = EngineOperation("image.score") { job in
    EngineCall(ImageQualityScoreRequest(image: try job.image("image")))
}

/// Defect detection (Gaea's helper for restore's scratches): a mask of scratches, dust and tears, `kind` `binary` (the
/// default) or `softAlpha`, at `threshold` when given.
///
/// BOPBTL runs on a CPU stream its package pins. There MLX JIT-compiles a fused kernel into a dylib and loads it, which
/// the hardened runtime's library validation refuses, and the run never ends. So it runs uncompiled, on MLX's own CPU
/// kernels: the same mask, byte for byte, and no C++ compiler needed on the server (AB-T-0377). The switch is global, and
/// safe here: the worker runs one job at a time.
let defects = EngineOperation(defectsHelper) { job, session in
    let kind: Matte.Kind = job.param("kind")?.stringValue == "softAlpha" ? .softAlpha : .binary
    let request = DefectDetectRequest(image: try job.image("image"), preferredKind: kind,
                                      threshold: job.param("threshold")?.doubleValue.map(Float.init))
    MLX.compile(enable: false)
    defer { MLX.compile(enable: true) }
    guard let response = try await session.run(request) as? DefectDetectResponse else {
        throw GPPError(.internal, "The defect detector returned no mask.")
    }
    let url = session.outputDir.appending(path: "mask-0.png")
    try response.mask.data.write(to: url)
    var outputs: [Output] = [.file("mask", url, mediaType: "image/png")]
    if let threshold = response.appliedThreshold { outputs.append(.value("applied_threshold", .double(Double(threshold)))) }
    return RunResult(outputs: outputs, effective: ["kind": .string(kind.rawValue)])
}

/// The helper Gaea calls defect detection as (Gaea's `GaeaModelHost.defectsHelper`).
let defectsHelper = "x-gaea.image.defects"

/// A generative stills upscale (VOSR2, Nacre) behind ForgeCore's text-legibility guard, never bare (AB-D-0111), as
/// pixel-agency-image-engine runs it through `EngineImageEnhancer.upscaleReporting`: the guard reads the input with the
/// policy the tier pair earned (`EngineTextGuardedUpscaler.measuredPolicy`), then runs the generative tier, the fast tier
/// (NERVE), or both composited under the words it protects. `upscale_model` names what made the pixels.
func guardedUpscale(_ generative: ForgeModel, base: ForgeModel = .upscale, baseID: String = "nerve-upscale") -> EngineOperation {
    EngineOperation("image.upscale") { job, session in
        let scale = job.param("scale")?.intValue == 2 ? 2 : 4
        // The enhancer's hops: the call's image to a CGImage, to the 8-bit raw image each tier is sent, and back.
        let source = try EngineImageCoding.cgImage(from: EngineImageCoding.rawImage(
            from: EngineImageCoding.cgImage(from: try job.image("image")), keepingDepth: false))
        let policy = await EngineTextGuardedUpscaler.measuredPolicy(for: generative)
        let verdict = try TextLegibilityGuard.assess(source, policy: policy)
        func run(_ model: String?) async throws -> CGImage {
            let request = ImageUpscaleRequest(image: try EngineImageCoding.rawImage(from: source, keepingDepth: false), scale: scale)
            let response = if let model { try await session.run(request, model: model) } else { try await session.run(request) }
            guard let up = response as? ImageUpscaleResponse else { throw GPPError(.internal, "The upscaler returned no image.") }
            return try EngineImageCoding.cgImage(from: up.image)
        }
        let image: CGImage
        let ran: String
        // EngineImageEnhancer.guardedModelName's names.
        switch verdict.recommendation {
        case .generative:
            image = try await run(nil)
            ran = generative.modelName
        case .keepBase:
            image = try await run(baseID)
            ran = "\(base.modelName) (legible document kept)"
        case .protectWords:
            let painted = try await run(nil), kept = try await run(baseID)
            let mask = try TextLegibilityGuard.mask(for: verdict, width: painted.width, height: painted.height, policy: policy)
            image = try TextLegibilityGuard.composite(base: kept, generative: painted, mask: mask)
            ran = "\(generative.modelName) + \(base.modelName) (protected words)"
        }
        let url = session.outputDir.appending(path: "image-0.png")
        try EngineImageCoding.pngImage(from: image).data.write(to: url)
        let applied = Int((Double(image.width) / Double(source.width)).rounded())
        return RunResult(outputs: [.file("image", url, mediaType: "image/png"), .value("upscale_model", .string(ran)),
                                   .value("applied_scale", .int(Int64(applied)))],
                         effective: ["scale": .int(Int64(scale)), "guard_route": .string(verdict.recommendation.rawValue)])
    }
}

// MARK: - The pack

/// Each in the configuration ForgeEngineService registers it with (ForgeCore 0.43.0), under the catalog's id.
let entries: [ForgeEntry] = [
    entry(InpaintPackage.self, InpaintConfiguration(), id: "lama-inpaint", title: "LaMa inpaint", operation: fill,
          speed: "fast", notes: "Removes the masked region and fills it from the picture. MI-GAN at draft.", maxPixels: 2048 * 2048),
    entry(NERVEUpscalePackage.self, NERVEConfiguration(), id: "nerve-upscale", title: "NERVE upscale", operation: upscale,
          speed: "fast", notes: "Fast ×2 and ×4 super-resolution (CC0-trained).", maxPixels: 2048 * 2048),
    entry(RealPLKSRUpscalePackage.self, RealPLKSRConfiguration(), id: "realplksr-upscale", title: "RealPLKSR upscale",
          operation: upscale, speed: "standard", notes: "Fidelity ×4 super-resolution trained on Commons-SR.", maxPixels: 2048 * 2048),
    entry(HEARTUpscalePackage.self, HEARTConfiguration(), id: "heart-upscale", title: "HEART upscale", operation: upscale,
          speed: "slow", notes: "High-fidelity ×4 window-attention upscaler; slower.", maxPixels: 1536 * 1536),
    entry(BiRefNetPackage.self, BiRefNetConfiguration(), id: "birefnet-matte", title: "BiRefNet matte", operation: matte,
          speed: "fast", notes: "Foreground matte and background removal.", maxPixels: 4096 * 4096),
    entry(EdgeTAMPackage.self, EdgeTAMConfiguration(), id: "edgetam-segment", title: "EdgeTAM segment", operation: segment,
          speed: "fast", notes: "Segments the object at the given points or box; the fast tier.", maxPixels: 4096 * 4096),
    entry(SAM21Package.self, SAM21Configuration(), id: "sam21-segment", title: "SAM 2.1 segment", operation: segment,
          speed: "fast", notes: "Higher-quality promptable segmentation (SAM 2.1-Small).", maxPixels: 4096 * 4096),
    // ForgeEngineService's restoreVariant default.
    entry(NAFNetRestorePackage.self, NAFNetConfiguration(variant: .signage), id: "nafnet-restore", title: "NAFNet restore",
          operation: restore, speed: "fast", notes: "Conservative general restoration: denoise and deblur.", maxPixels: 4096 * 4096),
    entry(RestormerRestorePackage.self, RestormerConfiguration(variant: .motionDeblur), id: "restormer-motion",
          title: "Restormer motion deblur", operation: restore, speed: "standard", notes: "Motion-blur removal.", maxPixels: 4096 * 4096),
    entry(RestormerRestorePackage.self, RestormerConfiguration(variant: .defocusDeblur), id: "restormer-defocus",
          title: "Restormer defocus deblur", operation: restore, speed: "standard", notes: "Defocus-blur removal.", maxPixels: 4096 * 4096),
    entry(RestormerRestorePackage.self, RestormerConfiguration(variant: .realDenoise), id: "restormer-denoise",
          title: "Restormer denoise", operation: restore, speed: "standard", notes: "Real-noise denoising.", maxPixels: 4096 * 4096),
    entry(DRUNetRestorePackage.self, DRUNetConfiguration(), id: "drunet-denoise", title: "DRUNet denoise", operation: restore,
          speed: "fast", notes: "Denoising with a strength dial (params.strength).", maxPixels: 4096 * 4096),
    entry(SCUNetRestorePackage.self, SCUNetConfiguration(variant: .realPSNR), id: "scunet-denoise", title: "SCUNet denoise",
          operation: restore, speed: "slow", notes: "Strong blind denoising.", maxPixels: 4096 * 4096),
    entry(GFPGANRestorePackage.self, GFPGANConfiguration(), id: "gfpgan-face", title: "GFPGAN face restore", operation: restore,
          speed: "standard", notes: "Face restoration (GFPGAN v1.4).", maxPixels: 4096 * 4096),
    entry(RestoreFormerRestorePackage.self, RestoreFormerConfiguration(), id: "restoreformer-face",
          title: "RestoreFormer++ face restore", operation: restore, speed: "standard", notes: "Face restoration with a VQ dictionary.",
          maxPixels: 4096 * 4096),
    // 0.2.0 (AB-T-0377): what pixel-agency-image-engine v0.9.1 serves from ForgeCore and 0.1.x left out.
    entry(CIDNetRelightPackage.self, CIDNetConfiguration(), id: "cidnet-relight", title: "HVI-CIDNet relight", operation: relight,
          speed: "fast", notes: "Exposure correction for under- and over-exposed images (params.strength).", maxPixels: 4096 * 4096),
    entry(DDColorPackage.self, DDColorConfiguration(), id: "ddcolor-colorize", title: "DDColor colorize", operation: colorize,
          speed: "fast", notes: "Colorizes black-and-white photos.", maxPixels: 4096 * 4096),
    // ForgeCore's `FORGE_IQA_PATCHES` default: 32 native-scale 224² patches, ~38 % of a 2048² frame.
    entry(SigLIP2IQAPackage.self, SigLIP2IQAConfiguration(maxPatches: 32), id: "siglip2-quality", title: "SigLIP2 quality score",
          operation: score, speed: "fast", notes: "No-reference image quality score (higher is better).", maxPixels: 4096 * 4096),
    entry(Anime4KUpscalePackage.self, Anime4KUpscaleConfiguration(), id: "anime4k-upscale", title: "Anime4K VL",
          operation: upscale, speed: "fast",
          notes: "Instant, model-free ×2 and ×4 upscaler on Metal shaders (MIT, nothing to download): the efficient choice, "
              + "not a quality rival to the learned tiers.", maxPixels: 2048 * 2048),
    entry(VOSRUpscalePackage.self, VOSRConfiguration(quant: .fp16, defaultScale: 2), id: "vosr2-upscale", title: "VOSR2 upscale",
          operation: guardedUpscale(.upscaleGenerative), speed: "slow", memory: "medium",
          notes: "Generative ×4 stills upscaler (Apache-2.0 DiT), behind the text-legibility guard. Stills only.",
          maxPixels: 1024 * 1024),
    entry(NacreUpscalePackage.self, NacreConfiguration(), id: "nacre-upscale", title: "Nacre upscale",
          operation: guardedUpscale(.upscaleNacre), speed: "slow", memory: "medium",
          notes: "Provenance-clean generative ×4 upscaler (Apache-2.0, Commons-trained), behind the text-legibility guard.",
          maxPixels: 1024 * 1024),
]

/// BOPBTL's scratch detector, the helper restore's scratches call before inpainting (no MES operation of its own).
let defectDetector = model(BOPBTLDetectPackage.self, BOPBTLConfiguration(), id: "bopbtl-defects", title: "BOPBTL defect detection",
                           operations: [defects])

public let forgePlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.forge",
    version: "0.2.0",
    minGaea: "0.6.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize/gaea-plugin-forge",
    title: "Forge processing pack",
    summary: "ForgeCore's image models in one process: inpaint (LaMa, MI-GAN), upscale (NERVE, RealPLKSR, HEART, Anime4K VL, "
        + "and VOSR2 and Nacre behind the text guard), matte (BiRefNet), segment (EdgeTAM, SAM 2.1), restore (NAFNet, Restormer, "
        + "DRUNet, SCUNet, GFPGAN, RestoreFormer++, and BOPBTL's defect detection for scratches), relight (HVI-CIDNet), "
        + "colorize (DDColor) and score (SigLIP2), for Gaea's image normalizer to compose.",
    license: "Apache-2.0",
    executable: "gaea-forge-worker",
    models: entries.map(\.model) + [defectDetector],
    offers: entries.map(\.offer),
    helpers: [PluginManifest.Helper(operation: defectsHelper, model: "bopbtl-defects", title: "Defect detection",
                                    summary: "Finds scratches, dust and tears on old photos; restore's scratches inpaint them.",
                                    params: ["type": "object", "properties": [
                                        "kind": ["type": "string", "enum": ["binary", "softAlpha"], "default": "binary"],
                                        "threshold": ["type": "number", "minimum": 0, "maximum": 1],
                                    ]])])

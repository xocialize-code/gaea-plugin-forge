import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXBiRefNet
import MLXEdgeTAM
import MLXGFPGAN
import MLXHEART
import MLXInpaint
import MLXNAFNet
import MLXNERVE
import MLXRealPLKSR
import MLXRestoreFormer
import MLXRestormer
import MLXSCUNet
import MLXToolKit

// gaea-plugin-forge: the processing pack (Gaea AB-T-0369). ForgeCore's image models in one process, since a worker
// costs ~146 MB and these models are small: each registered in the configuration ForgeCore's ForgeEngineService
// registers it with, under mlx-image-runtime's catalog id, so the image normalizer's operation table finds it.
//
// Gaea's image normalizer composes them: it calls each model as the plugin's offer of that capability's operation and
// applies the Image profile's rules (exact scale, black-mask pixels kept, alpha, sizes). The worker maps one call onto
// the engine: inpaint (LaMa, or MI-GAN as its `fast` mode), upscale (NERVE, RealPLKSR, HEART), matte (BiRefNet),
// segment (EdgeTAM, SAM 2.1) and restore (NAFNet, Restormer's three variants, SCUNet, GFPGAN, RestoreFormer++). Weights
// come from the models root Gaea sends in configure, or the package itself; the engine materializes what's missing.

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
                            operation: EngineOperation, speed: String, notes: String, maxPixels: Int) -> ForgeEntry {
    let resolved = ResolvedLane(manifest: P.manifest, configuration: configuration)
    let lane = resolved.quant?.rawValue ?? resolved.footprintQuant?.rawValue ?? "default"
    return ForgeEntry(
        model: .engine(package, id: id, title: title, lanes: [LaneDefinition(id: lane, default: true, configuration: configuration)],
                       operations: [operation]),
        offer: offer(operation.operation, id: id, title: title, manifest: P.manifest, speed: speed, notes: notes, maxPixels: maxPixels))
}

func offer(_ operation: String, id: String, title: String, manifest: PackageManifest, speed: String, notes: String,
           maxPixels: Int) -> PluginManifest.Offer {
    PluginManifest.Offer(
        operation: operation, profile: "image",
        model: ["id": .string(id), "title": .string(title), "license": license(manifest), "memory_class": "small",
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
    entry(SCUNetRestorePackage.self, SCUNetConfiguration(variant: .realPSNR), id: "scunet-denoise", title: "SCUNet denoise",
          operation: restore, speed: "slow", notes: "Strong blind denoising.", maxPixels: 4096 * 4096),
    entry(GFPGANRestorePackage.self, GFPGANConfiguration(), id: "gfpgan-face", title: "GFPGAN face restore", operation: restore,
          speed: "standard", notes: "Face restoration (GFPGAN v1.4).", maxPixels: 4096 * 4096),
    entry(RestoreFormerRestorePackage.self, RestoreFormerConfiguration(), id: "restoreformer-face",
          title: "RestoreFormer++ face restore", operation: restore, speed: "standard", notes: "Face restoration with a VQ dictionary.",
          maxPixels: 4096 * 4096),
]

public let forgePlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.forge",
    version: "0.1.1",
    minGaea: "0.4.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize/gaea-plugin-forge",
    title: "Forge processing pack",
    summary: "ForgeCore's image models in one process: inpaint (LaMa, MI-GAN), upscale (NERVE, RealPLKSR, HEART), "
        + "matte (BiRefNet), segment (EdgeTAM, SAM 2.1) and restore (NAFNet, Restormer, SCUNet, GFPGAN, RestoreFormer++), "
        + "for Gaea's image normalizer to compose.",
    license: "Apache-2.0",
    executable: "gaea-forge-worker",
    models: entries.map(\.model),
    offers: entries.map(\.offer))

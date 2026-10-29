// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-forge: the processing pack, ForgeCore's image models as one Gaea plugin (AB-T-0369). One worker
// executable built on GaeaPluginKit over the model packages ForgeCore registers, each in the configuration ForgeCore
// registers it with, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// The worker links ForgeCore too (0.2.0): Anime4K VL's package lives there, and VOSR2 and Nacre run behind its
// text-legibility guard, as pixel-agency-image-engine runs them (AB-T-0377). It registers only the pack's models.
//
// forge-inproc is not part of the plugin: it runs the same models in-process through ForgeCore's own
// ForgeEngineService, on this package's one dependency resolution, as the golden output a run through Gaea is compared
// against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-forge",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize/gaea-plugin-kit.git", from: "0.3.1"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
        .package(url: "https://github.com/xocialize/ForgeCore.git", exact: "0.43.0"),
        // The model packages, at ForgeCore's floors; SwiftPM resolves one version of each for the worker and ForgeCore.
        .package(url: "https://github.com/xocialize/mlx-lama-swift.git", from: "0.4.0"),
        .package(url: "https://github.com/xocialize/mlx-nerve-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/xocialize/mlx-birefnet-swift.git", from: "0.4.0"),
        .package(url: "https://github.com/xocialize/mlx-edgetam-swift.git", from: "0.6.0"),
        .package(url: "https://github.com/xocialize/mlx-nafnet-swift.git", from: "0.6.1"),
        .package(url: "https://github.com/xocialize/mlx-realplksr-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/xocialize/mlx-heart-swift.git", from: "0.2.2"),
        .package(url: "https://github.com/xocialize/mlx-restormer-swift.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/mlx-scunet-swift.git", from: "0.1.2"),
        .package(url: "https://github.com/xocialize/mlx-gfpgan-swift.git", from: "0.3.1"),
        .package(url: "https://github.com/xocialize/mlx-restoreformer-swift.git", from: "0.3.1"),
        .package(url: "https://github.com/xocialize/mlx-drunet-swift.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/mlx-cidnet-swift.git", from: "0.1.2"),
        .package(url: "https://github.com/xocialize/mlx-ddcolor-swift.git", from: "0.3.0"),
        .package(url: "https://github.com/xocialize/mlx-siglip2-iqa-swift.git", from: "0.4.0"),
        .package(url: "https://github.com/xocialize/mlx-bopbtl-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/xocialize/mlx-vosr-swift.git", from: "0.3.1"),
        .package(url: "https://github.com/xocialize/mlx-nacre-swift.git", from: "0.1.6"),
        .package(url: "https://github.com/xocialize/MaskKit.git", from: "0.5.0"),
        // MLX itself, for one switch: BOPBTL's run goes uncompiled (ForgePlugin.swift, `defects`).
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.3"),
    ],
    targets: [
        .target(
            name: "ForgePlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXInpaint", package: "mlx-lama-swift"),
                .product(name: "MLXNERVE", package: "mlx-nerve-swift"),
                .product(name: "MLXBiRefNet", package: "mlx-birefnet-swift"),
                .product(name: "MLXEdgeTAM", package: "mlx-edgetam-swift"),
                .product(name: "MLXNAFNet", package: "mlx-nafnet-swift"),
                .product(name: "MLXRealPLKSR", package: "mlx-realplksr-swift"),
                .product(name: "MLXHEART", package: "mlx-heart-swift"),
                .product(name: "MLXRestormer", package: "mlx-restormer-swift"),
                .product(name: "MLXSCUNet", package: "mlx-scunet-swift"),
                .product(name: "MLXGFPGAN", package: "mlx-gfpgan-swift"),
                .product(name: "MLXRestoreFormer", package: "mlx-restoreformer-swift"),
                .product(name: "MLXDRUNet", package: "mlx-drunet-swift"),
                .product(name: "MLXCIDNet", package: "mlx-cidnet-swift"),
                .product(name: "MLXDDColor", package: "mlx-ddcolor-swift"),
                .product(name: "MLXSigLIP2IQA", package: "mlx-siglip2-iqa-swift"),
                .product(name: "MLXBOPBTL", package: "mlx-bopbtl-swift"),
                .product(name: "MLXVOSR", package: "mlx-vosr-swift"),
                .product(name: "MLXNacre", package: "mlx-nacre-swift"),
                .product(name: "MaskKit", package: "MaskKit"),
                .product(name: "ForgeCore", package: "ForgeCore"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-forge-worker",
            dependencies: [
                "ForgePlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "forge-inproc",
            dependencies: [
                .product(name: "ForgeCore", package: "ForgeCore"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

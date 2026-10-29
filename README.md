# gaea-plugin-forge

The processing pack: [ForgeCore](https://github.com/xocialize/ForgeCore)'s image models as one
[Gaea](https://github.com/xocialize-code/gaea) plugin, in one process. A worker costs about 146 MB, so small models share
one. Each model is registered in the configuration ForgeCore's `ForgeEngineService` registers it with, under the id
mlx-image-runtime's catalog gives it, so Gaea's image normalizer composes them with the Image profile's rules (exact
×scale, black-mask pixels kept, alpha re-applied, sizes) and chooses among them by its measured tiers. Add it by its
repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-forge
```

## What it offers

| MES operation | Models (catalog id) | Gaea's default |
|---|---|---|
| `image.fill`, `image.erase`, `image.extend` | `lama-inpaint`: LaMa, and MI-GAN as its `fast` mode (draft) | LaMa |
| `image.upscale` | `nerve-upscale` (×2 and ×4), `realplksr-upscale` (×4), `heart-upscale` (×4, slower), `anime4k-upscale` (Anime4K VL, instant), `vosr2-upscale` and `nacre-upscale` (generative, behind the text guard) | RealPLKSR; HEART at best. Anime4K, VOSR2 and Nacre by name |
| `image.matte` | `birefnet-matte` | BiRefNet |
| `image.segment` | `edgetam-segment` (fast), `sam21-segment` (SAM 2.1-Small) | SAM 2.1; EdgeTAM at draft |
| `image.restore` | `nafnet-restore`, `restormer-motion`, `restormer-defocus`, `restormer-denoise`, `drunet-denoise`, `scunet-denoise`, `gfpgan-face`, `restoreformer-face` | by `kind`: NAFNet for general, SCUNet for denoise, Restormer for deblur, GFPGAN for faces. DRUNet by name |
| `image.relight` | `cidnet-relight` (HVI-CIDNet) | CIDNet |
| `image.colorize` | `ddcolor-colorize` | DDColor |
| `image.score` | `siglip2-quality` (SigLIP2 no-reference IQA, 32 patches) | SigLIP2 |
| helper `x-gaea.image.defects` | `bopbtl-defects` (BOPBTL scratch detection) | restore's `scratches`: the defects, then LaMa inpaints them |

The worker maps one model call onto its engine capability (`imageInpaint`, `imageUpscale`, `matting`,
`promptSegment`, `imageRestore`, `imageRelight`, `imageColorize`, `imageQualityScore`, `defectDetect`); Gaea's
normalizer plans the job around it. Every model has one lane, in the quant ForgeCore runs it at. NERVE's, RealPLKSR's
and NAFNet's weights ship inside the plugin, and Anime4K VL has none (Metal shaders); the others come from the models
root Gaea sends in `configure` (MLXEngine's store by default), and the engine downloads a missing one on `prepare`.

VOSR2 and Nacre run behind ForgeCore's text-legibility guard, never bare, as pixel-agency-image-engine runs them
(`EngineImageEnhancer`, AB-D-0111): the guard reads the input with the policy each pair earned
(`EngineTextGuardedUpscaler.measuredPolicy`), then runs the generative tier, NERVE, or both composited under the words
it protects (Nacre's policy protects words). The result names what made it (`upscale_model`). The worker links
ForgeCore for this and for Anime4K VL's package, and registers only the pack's models.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`build-plugin.sh` builds the worker in a scratch folder of its own and copies every SwiftPM resource bundle it links
into the plugin's `Contents/Resources`, where the packages' bundled weights are found. `check-plugin.sh` restores the
fixture photo with NAFNet over GPP, with every `.build` folder hidden; a control then shows that the bare worker,
outside the bundle, can't find MLX's metallib.

```bash
swift build -c release --product forge-inproc && scripts/golden.sh <out-dir>
```

`golden.sh` calls every model over GPP on the signed bundle and compares its output with ForgeCore's own
`ForgeEngineService` running the same call in-process (`forge-inproc`, on this package's one dependency resolution):
25 calls: 23 images byte-identical, and 2 scores the same value. The upscalers behind the guard are compared with
ForgeCore's own `EngineImageEnhancer` (`sign-256.png` takes Nacre through word protection). `scripts/make-fixtures.swift`
rebuilds the inputs 0.2.0 added.

`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
See the [demo plugin](https://github.com/xocialize-code/gaea-plugin-demo) for signing, notarization and CI secrets.

## Licence

The plugin is Apache-2.0 (Gaea G-21). Each model offer states its weights' licence from its package's manifest
(Apache-2.0 or MIT for every model here); the ports are MIT or Apache-2.0. VOSR2's weights are Apache-2.0 on an
undisclosed training corpus, which the fleet ships under posture A (AB-D-0105); Nacre is xocialize's, trained on
Wikimedia Commons CC0, PD and CC BY images.

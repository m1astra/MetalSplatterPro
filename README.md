# MetalSplatterPro
Generate and render 3D Gaussian Splats on Apple platforms (visionOS/iOS) using Metal + Core ML.

![A greek-style bust of a woman made of metal, wearing aviator-style goggles while gazing toward colorful abstract metallic blobs floating in space](http://metalsplatter.com/hero.640.jpg)

This repo contains:
- **MetalSplatter**: the Metal renderer for 3D Gaussian Splats (PLY / .splat)
- **SampleApp (MetalSplatterPro)**: a research demo that can **generate** a Gaussian Splat from a single image using a Core ML model (downloaded separately), then immediately view it in an immersive renderer.

Supported targets are defined in the Xcode project; the main intended target is **visionOS**.

## SampleApp workflow (what it does now)

- **Open File**: load an existing `.ply`, `.plysplat`, or `.splat` for viewing
- **Generate**: pick an image (`.jpg/.png/.heic`) → runs `sharp.mlmodelc` → writes a **binary little-endian PLY** into the app’s Documents folder → you can **View** it or **Save/Export** it

Notes:
- The generator uses **EXIF focal length** when available; otherwise it falls back to a reasonable default.
- The model produces a *lot* of gaussians (on the order of ~1.18M), so memory pressure is real.
- On **simulator**, generation is mocked.

## Getting Started

1. Open `SampleApp/MetalSplatter_SampleApp.xcodeproj`
2. Install the model:
   - Preferred (script): from repo root run `./scripts/fetch_model.sh`
   - Manual: download the model zip (see below), unzip it, and place `sharp.mlmodelc/` at `SampleApp/Scene/sharp.mlmodelc/`
2. Select your target and set your **Development Team** + **Bundle ID** in Signing & Capabilities
3. Build/run
4. In the app:
   - **Generate** → choose an image → wait for completion → **View**
   - (Optional) **Save** to export the generated `.ply` elsewhere

### Model download

- **Model zip URL**: `__MODEL_ZIP_URL__`
- **sha256**: `__MODEL_ZIP_SHA256__`

## Model license (IMPORTANT / research-only)

This project uses a Core ML model artifact derived from Apple's SHARP research model (distributed separately via the Model download link above):

- `SampleApp/Scene/sharp.mlmodelc`

**Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.**

The redistributed model artifacts are **Model Derivatives** and are provided **exclusively for Research Purposes** (non-commercial scientific research / academic development). “Research Purposes” does **not** include commercial exploitation, product development, or use in any commercial product or service.

See:
- `LICENSE_MODEL` (full terms)
- `MODEL_DERIVATIVE_NOTES.md` (what changed / derivative disclosure)
- `MODEL_ATTRIBUTION.txt` (attribution sentence, verbatim)

### Code license

The MetalSplatter source code in this repository is licensed under **MIT** (see `LICENSE`). The model artifact at `SampleApp/Scene/sharp.mlmodelc` is licensed separately under `LICENSE_MODEL`.

### No endorsement

This project is not affiliated with, sponsored by, or endorsed by Apple. Apple’s name, trademarks, or logos may not be used to endorse or promote this project.


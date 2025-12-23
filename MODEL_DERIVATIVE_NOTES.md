## Model derivative notes (SHARP)

This project uses Core ML model artifacts derived from Apple's SHARP research model.

The model bundle is **not stored in git** due to size; it is distributed separately (see `README.md` → “Model download”) and installed into the path below.

- **Location**: `SampleApp/Scene/sharp.mlmodelc`
- **License**: `LICENSE_MODEL` (research-only)

### Attribution (required)

Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.

### What changed (derivative disclosure)

- Converted original model weights to FP16 for on-device execution
- Converted / packaged into Core ML (`.mlmodelc`)
- No retraining or fine-tuning performed

### No endorsement

This project is not affiliated with, sponsored by, or endorsed by Apple.



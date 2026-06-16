# FLUX.2

Black Forest Labs' FLUX.2 diffusion models for on-device image generation via Core AI.

## Supported Models

| Model           | Parameters | macOS | iOS |
| --------------- | ---------- | ----- | --- |
| FLUX.2 Klein 4B | 4B         | Yes   | Yes |

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```bash
# Export for iOS (512x512 image resolution by default)
uv run coreai.diffusion.export flux2-klein-4b --platform iOS

# Override resolution (e.g. full 1024 on iOS)
uv run coreai.diffusion.export flux2-klein-4b --platform iOS --resolution 1024

# Export for macOS (1024x1024 image resolution by default)
uv run coreai.diffusion.export flux2-klein-4b --platform macOS

# Include half-resolution VAEs for low-memory tiled decode
uv run coreai.diffusion.export flux2-klein-4b --platform macOS --low-memory

# Export all components (default -- no --platform flag)
uv run coreai.diffusion.export flux2-klein-4b
```

**Other options:**

```bash
# Full precision (no compression)
uv run coreai.diffusion.export flux2-klein-4b --compression none

# Export specific components only
uv run coreai.diffusion.export flux2-klein-4b --components transformer text_encoder

# Custom output directory
uv run coreai.diffusion.export flux2-klein-4b --output-dir ./my-models/

# Preview resolved config without exporting
uv run coreai.diffusion.export flux2-klein-4b --dry-run
```

## Components

| Component          | Description                                         | Platform           |
| ------------------ | --------------------------------------------------- | ------------------ |
| `transformer`      | DiT (25 blocks), 1024x1024 image resolution         | macOS              |
| `transformer_512`  | DiT (25 blocks), 512x512 image resolution           | iOS                |
| `text_encoder`     | Qwen3 encoder (intermediate layers 9, 18, 27)       | all                |
| `vae_decoder`      | Latent to 1024x1024 pixel image                     | macOS              |
| `vae_decoder_half` | Latent to 512x512 pixel image                       | iOS, macOS+low-mem |
| `vae_encoder`      | 1024x1024 pixel image to latent (image-to-image)    | macOS              |
| `vae_encoder_half` | 512x512 pixel image to latent (image-to-image)      | iOS, macOS+low-mem |

## Running

### In your iOS and macOS applications

```swift
import CoreAIDiffusionPipeline

// Pipeline auto-detects the best mode from available components
let pipeline = try await Flux2Pipeline(from: modelURL)

let config = PipelineConfiguration(
    prompt: "a photo of a cat",
    stepCount: 4,
    guidanceScale: 1.0,
    schedulerType: .discreteFlow
)

let result = try await pipeline.generateImages(
    configuration: config,
    progressHandler: { progress in
        print("Step \(progress.step)/\(progress.totalSteps)")
        return true
    }
)

let image = result.images.first!
```

### On your Mac using built-in Command Line Tool

```bash
swift run -c release diffusion-runner --model path/to/exported_model_folder --prompt "a photo of a cat" --steps 4 --guidance-scale 1.0
```

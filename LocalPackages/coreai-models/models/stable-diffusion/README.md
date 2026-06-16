# Stable Diffusion

Stability AI's Stable Diffusion models for on-device image generation via Core AI.

## Supported Models

| Model                       | Parameters | macOS | iOS |
| --------------------------- | ---------- | ----- | --- |
| Stable Diffusion 1.5        | 0.9B       | Yes   | Yes |
| Stable Diffusion 2.1        | 0.9B       | Yes   | Yes |
| Stable Diffusion 3.5 Medium | 2.5B       | Yes   | Yes |

## Gated Access
Some Stable Diffusion models are gated on [Hugging Face](https://huggingface.co/stabilityai/stable-diffusion-3.5-medium) (HF). You will need to accept the terms of the license on the model page, generate a HF token, and add your HF token to your machine before exporting these models.
```bash
brew install hf
hf auth login --token <YOUR_TOKEN_HERE>
```

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```bash
# Stable Diffusion 1.5
uv run coreai.diffusion.export runwayml/stable-diffusion-v1-5

# Stable Diffusion 2.1
uv run coreai.diffusion.export sd2-community/stable-diffusion-2-1

# Stable Diffusion 3.5 Medium
uv run coreai.diffusion.export stabilityai/stable-diffusion-3.5-medium
```

**Other options:**

```bash
# Full precision (no compression)
uv run coreai.diffusion.export runwayml/stable-diffusion-v1-5 --compression none

# Export specific components only
uv run coreai.diffusion.export runwayml/stable-diffusion-v1-5 --components text_encoder unet

# Custom output directory
uv run coreai.diffusion.export runwayml/stable-diffusion-v1-5 --output-dir ./my-models/

# Preview resolved config without exporting
uv run coreai.diffusion.export runwayml/stable-diffusion-v1-5 --dry-run
```

## Components

### Stable Diffusion 1.x / 2.x

| Component      | Description                            |
| -------------- | -------------------------------------- |
| `text_encoder` | CLIP text encoder                      |
| `unet`         | Denoising U-Net                        |
| `vae_decoder`  | Latent to pixel image                  |
| `vae_encoder`  | Pixel image to latent (image-to-image) |

### Stable Diffusion 3.x

| Component        | Description                          |
| ---------------- | ------------------------------------ |
| `text_encoder`   | CLIP-L encoder (with pooled output)  |
| `text_encoder_2` | CLIP-G encoder (with pooled output)  |
| `transformer`    | MMDiT denoising transformer          |
| `vae_decoder`    | Latent to pixel image                |

## Running

### In your iOS and macOS applications

```swift
import CoreAIDiffusionPipeline

// SD 1.5 / 2.1
let pipeline = try await StableDiffusionPipeline.load(from: modelURL)

let config = PipelineConfiguration(
    prompt: "a photograph of an astronaut riding a horse",
    stepCount: 20,
    guidanceScale: 7.5,
    schedulerType: .dpmSolverMultistep
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
swift run -c release diffusion-runner --model path/to/exported_model_folder --prompt "a photograph of an astronaut riding a horse"
```

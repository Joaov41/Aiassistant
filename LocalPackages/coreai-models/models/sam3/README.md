# SAM 3

SAM 3 (Segment Anything Model 3) is a unified vision model from Meta for promptable image and video segmentation given text or visual prompts.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

### Gated Access
SAM3 is a gated model on [Hugging Face](https://huggingface.co/facebook/sam3) (HF). You will need to accept the terms of the [license](https://huggingface.co/facebook/sam3), generate a HF token, and add your HF token to your machine before exporting this model.
```bash
brew install hf
hf auth login --token <YOUR_TOKEN_HERE>
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>/` as a bundle directory containing `<model>_<dtype>.aimodel`, a `tokenizer/` folder, and a `metadata.json` (segmenter bundle, schema 0.2). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                       | Default                |
| -------------- | --------------------------------- | ---------------------- |
| `--model`      | Model variant                     | `facebook/sam3`        |
| `--output-dir` | Output directory for the bundle   | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `float32`              | `float32`              |
| `--overwrite`  | Overwrite existing bundle         | —                      |

> **Note:** Batch images and dynamic export are not currently supported.

**Supported models:**

| Model         | Parameters |
| ------------- | ---------- |
| facebook/sam3 | 848M       |

## Running

### In your iOS and macOS applications

```swift
import ImageSegmenter

// Load from a segmenter bundle directory (contains metadata.json, *.aimodel, and tokenizer/)
let segmenter = try await ImageSegmenter(resourcesAt: "coreai-models/exports/sam3_float16")

// Text prompt (SAM3):
let segments = try await segmenter.segment(image: cgImage, prompt: "cat")
```

### On your Mac using built-in Command Line Tool

```bash
swift run -c release image-segmenter --model path/to/exported_model_folder --prompt "cat" --image path/to/image.jpg
```

[^1]: [Paper](https://arxiv.org/abs/2511.16719) · [HuggingFace](https://huggingface.co/facebook/sam3)

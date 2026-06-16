# YOLOS

YOLOS (You Only Look at One Sequence) applies a plain Vision Transformer directly to image patches and predicts object queries as bounding boxes and class logits.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/hustvl_yolos-base_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                               | Default                |
| -------------- | --------------------------------------------------------- | ---------------------- |
| `--model`      | Model variant                                             | `hustvl/yolos-base`    |
| `--output-dir` | Output directory for `.aimodel`                           | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `bfloat16`, `float32`                          | `float32`              |
| `--overwrite`  | Overwrite existing `.aimodel`                             | —                      |
| `--dynamic`    | Dynamic batch (1–64), spatial (128–1024, multiples of 16) | —                      |

**Supported models:**

| Model             | Parameters |
| ----------------- | ---------- |
| hustvl/yolos-tiny | 6.5M       |
| hustvl/yolos-base | 127M       |

## Running

### In your iOS and macOS applications

```swift
import ObjectDetector

// Detection parameters
let params = DetectionParameters()

// Load directly from an exported .aimodel directory.
let detector = try await ObjectDetector(resourcesAt: "coreai-models/exports/yolos-base_float32_static.aimodel")

// Run inference
let detections = try await detector.detect(image: cgImage, parameters: params)
```

### On your Mac using built-in Command Line Tool

```bash
swift run -c release object-detector --model path/to/exported_model.aimodel --image path/to/image.jpg
```

[^1]: [Paper](https://arxiv.org/abs/2106.00666) · [HuggingFace](https://huggingface.co/hustvl/yolos-tiny)

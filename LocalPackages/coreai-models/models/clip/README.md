# CLIP

CLIP (Contrastive Language-Image Pretraining) learns joint representations of images and text, enabling zero-shot image classification with natural language labels.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/openai_clip-vit-base-patch32_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                                   | Default                        |
| -------------- | ------------------------------------------------------------- | ------------------------------ |
| `--model`      | Model variant                                                 | `openai/clip-vit-base-patch32` |
| `--output-dir` | Output directory for `.aimodel`                               | `<repo-root>/exports/`         |
| `--dtype`      | `float16`, `bfloat16`, `float32`                              | `float32`                      |
| `--overwrite`  | Overwrite existing `.aimodel`                                 | —                              |
| `--dynamic`    | Dynamic batch (image 1–64, text 1–64); spatial/sequence fixed | —                              |

**Supported models:**

| Model                        | Parameters |
| ---------------------------- | ---------- |
| openai/clip-vit-base-patch32 | 151M       |

[^1]: [Paper](https://arxiv.org/abs/2103.00020) · [HuggingFace](https://huggingface.co/openai/clip-vit-base-patch32)

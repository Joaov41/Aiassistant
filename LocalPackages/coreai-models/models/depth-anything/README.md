# Depth Anything v3

Monocular depth estimation model that predicts depth, confidence, camera intrinsics, and extrinsics from a batch of image views.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>.aimodel`. Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                    | Default                    |
| -------------- | ---------------------------------------------- | -------------------------- |
| `--model`      | Model variant                                  | `depth-anything/da3-small` |
| `--output-dir` | Output directory for `.aimodel`                | `<repo-root>/exports/`     |
| `--dtype`      | `float32` only (CPU LayerNorm upcasts float16) | `float32`                  |
| `--overwrite`  | Overwrite existing `.aimodel`                  | —                          |

**Supported models:**

| Model                    | Parameters |
| ------------------------ | ---------- |
| depth-anything/da3-small | 35M        |

[^1]: [Repository](https://github.com/ByteDance-Seed/Depth-Anything-3) · [HuggingFace](https://huggingface.co/depth-anything/da3-small)

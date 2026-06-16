# EDSR

EDSR (Enhanced Deep Residual Networks) upscales low-resolution images by a fixed integer factor (2x, 3x, 4x).[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/edsr_r16f64_x2_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                         | Default                |
| -------------- | --------------------------------------------------- | ---------------------- |
| `--model`      | Model variant                                       | `edsr_r16f64_x2`       |
| `--output-dir` | Output directory for `.aimodel`                     | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `bfloat16`, `float32`                    | `float32`              |
| `--overwrite`  | Overwrite existing `.aimodel`                       | —                      |
| `--dynamic`    | Dynamic batch (1–64), height (8–256), width (8–256) | —                      |

**Supported models:**

| Model          | Parameters |
| -------------- | ---------- |
| edsr_r16f64_x2 | 1.5M       |

[^1]: [Paper](https://arxiv.org/abs/1707.02921) · [torchSR](https://github.com/Coloquinte/torchSR)

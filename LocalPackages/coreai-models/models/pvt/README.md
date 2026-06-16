# PVT v2

Pyramid Vision Transformer — uses a pyramid structure as an effective backbone for dense prediction tasks.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/pvt_v2_b0_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                    | Default                |
| -------------- | ---------------------------------------------- | ---------------------- |
| `--model`      | Model variant                                  | `pvt_v2_b0`            |
| `--output-dir` | Output directory for `.aimodel`                | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `bfloat16`, `float32`               | `float32`              |
| `--overwrite`  | Overwrite existing `.aimodel`                  | —                      |
| `--dynamic`    | Dynamic batch (1–64); spatial fixed at 224x224 | —                      |

**Supported models:**

| Model     | Parameters |
| --------- | ---------- |
| pvt_v2_b0 | 3.7M       |

[^1]: [Paper](https://arxiv.org/abs/2102.12122) · [HuggingFace](https://huggingface.co/docs/transformers/model_doc/pvt)

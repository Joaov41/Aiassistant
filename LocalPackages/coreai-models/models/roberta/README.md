# RoBERTa

Transformer encoder model that improves on BERT by training with larger batches, more data, longer sequences, and without the next-sentence prediction objective.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/roberta-base_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                      | Default                |
| -------------- | ------------------------------------------------ | ---------------------- |
| `--model`      | Model variant                                    | `roberta-base`         |
| `--output-dir` | Output directory for `.aimodel`                  | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `bfloat16`, `float32`                 | `float32`              |
| `--overwrite`  | Overwrite existing `.aimodel`                    | —                      |
| `--dynamic`    | Dynamic batch (1–64) and sequence length (1–512) | —                      |

**Supported models:**

| Model        | Parameters |
| ------------ | ---------- |
| roberta-base | 125M       |

[^1]: [Paper](https://arxiv.org/abs/1907.11692) · [HuggingFace](https://huggingface.co/roberta-base)

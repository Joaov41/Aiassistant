# T5

Encoder-decoder models pre-trained on a mixture of unsupervised and supervised tasks.[^1] Works well on many tasks via input prefixes: `translate English to German: ...`, `summarize: ...`, etc.

Also supports FLAN-T5 variants.[^2]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/google-t5_t5-small_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                                                | Default                |
| -------------- | -------------------------------------------------------------------------- | ---------------------- |
| `--model`      | Model variant (see table below)                                            | `google-t5/t5-small`   |
| `--output-dir` | Output directory for `.aimodel`                                            | `<repo-root>/exports/` |
| `--dtype`      | `float16`, `float32`                                                       | `float32`              |
| `--overwrite`  | Overwrite existing `.aimodel`                                              | —                      |
| `--dynamic`    | Dynamic batch (1–64) and sequence lengths; float16 capped at 4096          | —                      |

**Supported models:**

| Model              | Parameters |
| ------------------ | ---------- |
| google-t5/t5-small | 60M        |
| google-t5/t5-base  | 220M       |
| google-t5/t5-large | 770M       |

FLAN variants: `google/flan-t5-small`, `google/flan-t5-base`, etc. See the [HuggingFace page](https://huggingface.co/docs/transformers/model_doc/flan-t5) for a complete list.

[^1]: [Paper](https://arxiv.org/abs/1910.10683) · [HuggingFace](https://huggingface.co/docs/transformers/model_doc/t5)
[^2]: [FLAN-T5 paper](https://arxiv.org/abs/2210.11416)

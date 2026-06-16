# CLAP

CLAP (Contrastive Language-Audio Pretraining) learns joint representations of audio and text, enabling zero-shot audio classification with natural language labels.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/laion_clap-htsat-unfused_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                       | Default                    |
| -------------- | ------------------------------------------------- | -------------------------- |
| `--model`      | Model variant                                     | `laion/clap-htsat-unfused` |
| `--output-dir` | Output directory for `.aimodel`                   | `<repo-root>/exports/`     |
| `--dtype`      | `float16`, `float32`                              | `float32`                  |
| `--overwrite`  | Overwrite existing `.aimodel`                     | —                          |
| `--dynamic`    | Dynamic text batch size (1–64); audio stays fixed | —                          |

**Supported models:**

| Model                    | Parameters |
| ------------------------ | ---------- |
| laion/clap-htsat-unfused | 153M       |

[^1]: [Paper](https://arxiv.org/abs/2211.06687) · [HuggingFace](https://huggingface.co/laion/clap-htsat-unfused)

# Whisper

Automatic speech recognition (ASR) encoder-decoder model from OpenAI, trained on a large multilingual and multitask supervised dataset.[^1]

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

| Flag           | Description                      | Default                         |
| -------------- | -------------------------------- | ------------------------------- |
| `--model`      | Model variant                    | `openai/whisper-large-v3-turbo` |
| `--output-dir` | Output directory for `.aimodel`  | `<repo-root>/exports/`          |
| `--dtype`      | `float16`, `bfloat16`, `float32` | `float32`                       |
| `--overwrite`  | Overwrite existing `.aimodel`    | —                               |

**Supported models:**

| Model                         | Parameters |
| ----------------------------- | ---------- |
| openai/whisper-large-v3-turbo | 809M       |
| openai/whisper-large-v3       | 1.54B      |

[^1]: [Paper](https://arxiv.org/abs/2212.04356) · [HuggingFace](https://huggingface.co/openai/whisper-large-v3)

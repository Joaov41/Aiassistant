# Wav2Vec 2.0

Self-supervised speech representation model that learns directly from raw audio and, after fine-tuning, transcribes speech into character-level token emissions.[^1]

## Setup

If you haven't installed `uv`, install it by

```bash
brew install uv
```

## Export

```sh
uv run export.py
```

Saves to `<repo-root>/exports/<model>_<dtype>_<static_or_dynamic>.aimodel` (e.g. `<repo-root>/exports/wav2vec2_asr_base_960h_float32_static.aimodel`). Pass `--output-dir <path>` to override the destination.

```sh
uv run export.py --help
```

**Options:**

| Flag           | Description                                             | Default                  |
| -------------- | ------------------------------------------------------- | ------------------------ |
| `--model`      | Model variant                                           | `wav2vec2_asr_base_960h` |
| `--output-dir` | Output directory for `.aimodel`                         | `<repo-root>/exports/`   |
| `--dtype`      | `float16`, `float32`                                    | `float32`                |
| `--overwrite`  | Overwrite existing `.aimodel`                           | —                        |
| `--dynamic`    | Dynamic batch (1–64) and audio length (min 720 samples) | —                        |

**Supported models:**

| Model                  | Parameters |
| ---------------------- | ---------- |
| wav2vec2_asr_base_960h | 95M        |

[^1]: [Paper](https://arxiv.org/abs/2006.11477) · [torchaudio docs](https://pytorch.org/audio/stable/pipelines.html)

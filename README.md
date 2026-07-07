# Aiassistant

Aiassistant is a macOS SwiftUI assistant app.

## Structure

- `Aiassistant/` - main macOS app source
- `AiassistantTests/` and `AiassistantUITests/` - test targets

## Notarized Build

Per request from people who cannot compile the app locally, a notarized macOS build is available on the [Releases page](https://github.com/Joaov41/Aiassistant/releases/latest).

## Apple PCC Note

When using Apple PCC, Terminal may appear in the Dock while the app routes the request through Apple's `fm` command-line tool. See Apple's [Build AI-powered scripts with the fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/) session for more about `fm`.

## Local MLX Setup Note

Local Gemma models are served by MLX Python command-line servers, not by the app bundle itself. If another Mac shows "Local MLX server is not reachable", the usual cause is a Python/MLX package mismatch or a missing server binary.

Install the known-good local MLX runtime with:

```zsh
script/setup_mlx_runtime.sh
```

The script creates:

- `~/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server`
- `~/Library/Application Support/Aiassistant/mlx-vlm-venv/bin/mlx_vlm.server`

Known-good versions:

- Text/E2B: `mlx-lm==0.31.2`, `mlx==0.31.1`, `transformers==5.12.1`, `huggingface-hub==1.19.0`
- Vision/E4B: `mlx-vlm==0.6.3`, `mlx-lm==0.31.3`, `mlx==0.31.2`, `transformers==5.12.1`

Requires Python 3.12, normally installed with:

```zsh
brew install python@3.12
```

For E2B on a new Mac, copy the working Hugging Face snapshot to:

```text
~/.cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots/99d9a53ff828d365a8ecae538e45f80a08d612cd
```

If the app still reports the server is unreachable, check the MLX logs:

```zsh
tail -160 /tmp/aiassistant-mlx-server.log
tail -160 /tmp/aiassistant-mlx-vlm-server.log
```

## License

This project is released under the [MIT License](LICENSE). You may share and modify it, but copies or substantial portions must keep the copyright notice for John Val.

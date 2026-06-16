# Aiassistant

Aiassistant is a macOS SwiftUI assistant app.

## Structure

- `Aiassistant/` - main macOS app source
- `AiassistantTests/` and `AiassistantUITests/` - test targets
- `LocalPackages/coreai-models/` - vendored CoreAI Swift package used by the local Gemma provider

## Latest Update

- Added a Local MLX Gemma provider with automatic local text and image server startup.
- Added CoreAI Gemma model download, installation checks, and Small E2B CoreAI runtime support.
- Updated Settings with Gemma model selection, status, and fallback command details.
- Added tests around provider selection, local Gemma prompt handling, and CoreAI model state.

## Install Local Gemma Dependencies

Local MLX Gemma is optional. Use it if you want Aiassistant to run supported Gemma models on your Mac instead of sending requests to Apple PCC. This path works best on Apple silicon Macs.

Open Terminal and run these commands one at a time:

```sh
xcode-select --install
```

If Homebrew is not installed yet, install it:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install Python:

```sh
brew install python@3.12
```

Create the Python environment that Aiassistant checks first:

```sh
mkdir -p "$HOME/Library/Application Support/Aiassistant"
python3.12 -m venv "$HOME/Library/Application Support/Aiassistant/mlx-venv"
```

Install the required Python packages:

```sh
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/python" -m pip install --upgrade pip
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/python" -m pip install mlx-lm mlx-vlm huggingface-hub
```

Check that the server commands were installed:

```sh
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server" --help
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_vlm.server" --help
```

If both commands print help text, open Aiassistant, go to Settings, choose Local MLX Gemma, and pick a Gemma model. The app starts the local text and image servers automatically when needed.

If Hugging Face asks you to log in for a model, run:

```sh
mkdir -p "$HOME/Library/Application Support/Aiassistant/huggingface-token"
HF_TOKEN_PATH="$HOME/Library/Application Support/Aiassistant/huggingface-token/token" \
  "$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/hf" auth login
```

## Notarized Build

Per request from people who cannot compile the app locally, a notarized macOS build is available on the [Releases page](https://github.com/Joaov41/Aiassistant/releases/latest).

## Apple PCC Note

When using Apple PCC, Terminal may appear in the Dock while the app routes the request through Apple's `fm` command-line tool. See Apple's [Build AI-powered scripts with the fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/) session for more about `fm`.

## License

This project is released under the [MIT License](LICENSE). You may share and modify it, but copies or substantial portions must keep the copyright notice for John Val.

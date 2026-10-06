# Aiassistant

Aiassistant is an open-source, native macOS AI assistant built with SwiftUI.

It is designed to bring AI directly into your Mac workflow instead of limiting it to a standalone chat window. Aiassistant can work with selected text, screenshots, files, URLs, images, and other context from the apps you are already using, then answer questions or rewrite content in place.

## Highlights

- Native macOS app built with SwiftUI
- System-wide assistant available from a global keyboard shortcut
- Chat and Rewrite in Place modes
- Selected-text capture through macOS Accessibility APIs
- Rewrite selected text directly inside the original app
- Screenshot capture of other application windows with ScreenCaptureKit
- Support for PDFs, text files, URLs, images, and video attachments
- Multi-turn conversations with recent conversation context
- Built-in and custom Quick Actions
- Multiple private and local AI backends
- No mandatory third-party cloud API account

## AI Providers

Aiassistant currently supports four provider paths.

### Apple Foundation Model — On Device

Uses Apple's on-device Foundation Models runtime through `SystemLanguageModel.default`.

- Runs locally on the Mac
- No API key
- No external AI service
- Best suited to fast, private everyday tasks

### Apple Private Cloud Compute

Uses Apple's Private Cloud Compute model directly through the FoundationModels framework with `PrivateCloudComputeLanguageModel`.

This is **not** routed through the `fm` command-line tool or a third-party gateway.

The app checks for Apple's managed PCC entitlement at runtime:

```text
com.apple.developer.private-cloud-compute
```

When the entitlement and model are available, requests are sent through Apple's native Private Cloud Compute path. PCC image understanding is also supported when the model reports vision capability.

Apple Private Cloud Compute currently requires macOS 27 or later and an app build signed with the required managed entitlement.

### Local MLX Gemma

Runs supported Gemma models locally on Apple silicon using MLX.

Aiassistant manages the local text and vision server processes when this provider is selected. This path is useful when you want a larger local model while keeping document and prompt content on your own Mac.

Supported model choices are exposed directly in Settings.

### Local OpenAI-Compatible Server

Aiassistant can connect to an OpenAI-compatible server running locally or on a network endpoint you control.

You can configure:

- Base URL
- Model ID
- Optional API key
- Output token limit
- Thinking behavior

Credentials are stored in the macOS Keychain.

This makes Aiassistant compatible with many self-hosted runtimes that expose an OpenAI-style chat-completions API.

## System-Wide Workflow

Aiassistant is designed to work around the content you are already viewing or editing.

### Selected Text

Select text in another application and invoke Aiassistant.

The app can read the current selection using macOS Accessibility APIs and use it as conversation context.

### Rewrite in Place

Switch to **Rewrite in Place**, give Aiassistant an instruction, and the generated result can replace the original selected text inside the source application.

The app verifies the Accessibility target before performing the replacement to reduce the risk of writing into the wrong field or window.

### Screenshots

Aiassistant uses ScreenCaptureKit to capture context from another application window.

Screenshots can be attached to a conversation and sent to providers that support image understanding.

### Files and Documents

Files can be dropped or attached directly to the assistant.

Current handling includes:

- PDF text extraction
- Text documents
- Images
- Video files
- URLs

PDF processing uses PDFKit, with additional Vision-based handling where needed.

### URLs

URLs can be supplied as context and Aiassistant can fetch their contents for use in a conversation or Quick Action.

## Quick Actions

Aiassistant includes context-aware Quick Actions for common tasks such as:

- Summarize
- Extract key points
- Simplify text
- Translate
- Describe an image
- Describe video content when supported by the active provider

You can also create your own custom Quick Actions in Settings.

Quick Actions can work from text, URLs, PDFs, images, and other supported context types. Text actions can also be used as part of the inline replacement workflow.

## Conversations

Aiassistant supports multi-turn conversations.

Recent user and assistant turns are included in follow-up requests so questions such as:

> What about the second point?

can be resolved using the existing conversation context.

Attached document, image, and other contextual data are managed separately from the conversation text so the active provider receives the relevant context for the current request.

## Privacy

Aiassistant gives you several ways to keep AI processing private:

| Provider | Where processing happens |
| --- | --- |
| Apple Foundation Model | On device |
| Apple Private Cloud Compute | Apple Private Cloud Compute |
| Local MLX Gemma | On your Mac |
| Local OpenAI-compatible server | Endpoint you configure |

There is no requirement to use OpenAI, Anthropic, Google, or another commercial AI API.

The local OpenAI-compatible provider stores its optional API credential in Keychain rather than UserDefaults.

## Requirements

Core requirements depend on the provider you want to use.

- A recent version of macOS
- Apple silicon is recommended and required for the intended MLX experience
- Apple Intelligence availability is required for Apple's on-device model
- Apple Private Cloud Compute requires macOS 27+ and Apple's managed PCC entitlement
- Local MLX requires the MLX runtime described below

## Download

A notarized macOS build is available from the latest GitHub release:

https://github.com/Joaov41/Aiassistant/releases/latest

You can also build Aiassistant from source with Xcode.

## Local MLX Setup

Local MLX is optional. You do not need it to use Apple's on-device Foundation Model or Private Cloud Compute.

The easiest way to install the known-good MLX runtime is:

```zsh
script/setup_mlx_runtime.sh
```

The setup creates local Python environments under:

```text
~/Library/Application Support/Aiassistant/
```

including the server binaries used by Aiassistant:

```text
~/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server
~/Library/Application Support/Aiassistant/mlx-vlm-venv/bin/mlx_vlm.server
```

### Manual MLX Setup

If you prefer to install the dependencies manually, install the Xcode command-line tools first:

```sh
xcode-select --install
```

Install Python 3.12:

```sh
brew install python@3.12
```

Create the local environment:

```sh
mkdir -p "$HOME/Library/Application Support/Aiassistant"
python3.12 -m venv "$HOME/Library/Application Support/Aiassistant/mlx-venv"
```

Install the MLX packages:

```sh
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/python" -m pip install --upgrade pip
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/python" -m pip install mlx-lm mlx-vlm huggingface-hub
```

Check the installed server commands:

```sh
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server" --help
"$HOME/Library/Application Support/Aiassistant/mlx-vlm-venv/bin/mlx_vlm.server" --help
```

Once installed, open Aiassistant, go to Settings, select **Local MLX Gemma**, and choose a model. The app starts the required local server automatically when needed.

### Hugging Face Authentication

Some models may require Hugging Face authentication.

```sh
mkdir -p "$HOME/Library/Application Support/Aiassistant/huggingface-token"
HF_TOKEN_PATH="$HOME/Library/Application Support/Aiassistant/huggingface-token/token" \
  "$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/hf" auth login
```

### Known-Good MLX Versions

The current setup script uses known-good combinations for the text and vision runtimes.

Text / E2B:

```text
mlx-lm==0.31.2
mlx==0.31.1
transformers==5.12.1
huggingface-hub==1.19.0
```

Vision / E4B:

```text
mlx-vlm==0.6.3
mlx-lm==0.31.3
mlx==0.31.2
transformers==5.12.1
```

### Troubleshooting Local MLX

If Aiassistant reports that the local MLX server is unreachable, the most common cause is a Python/MLX package mismatch or a missing server binary.

Check the logs:

```zsh
tail -160 /tmp/aiassistant-mlx-server.log
tail -160 /tmp/aiassistant-mlx-vlm-server.log
```

For the current E2B configuration, the expected Hugging Face snapshot location is:

```text
~/.cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/snapshots/99d9a53ff828d365a8ecae538e45f80a08d612cd
```

## Project Structure

- `Aiassistant/` — main macOS application
- `AiassistantTests/` — unit and integration tests
- `AiassistantUITests/` — UI tests
- `LocalPackages/coreai-models/` — vendored CoreAI Swift package used by the local Gemma provider
- `script/` — local runtime and development helper scripts

## Development

The app's provider layer currently separates the major execution paths into dedicated implementations:

- `AppleIntelligenceProvider`
- `PrivateCloudComputeProvider`
- `CoreAIGemmaProvider`
- `OpenAICompatibleLocalProvider`

This allows the UI and conversation system to work across multiple backends while keeping provider-specific behavior isolated.

## License

Aiassistant is released under the MIT License.

You may use, modify, and redistribute it under the terms of [LICENSE](LICENSE). Copies or substantial portions must retain the copyright notice for John Val.

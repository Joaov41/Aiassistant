# AI Assistant

AI Assistant is an open-source macOS menu-bar app for working with AI across your Mac. Ask questions about selected text, rewrite it inside another app, or attach a document or window capture for context.

Choose Apple's on-device Foundation Model, native Apple Private Cloud Compute, local MLX Gemma, or an OpenAI-compatible server you run yourself.

[Website](https://ai.assistant.community/) · [Download](https://github.com/Joaov41/Aiassistant/releases/latest) · [MIT license](LICENSE)

## Features

- Chat with follow-up questions, Markdown responses, copy controls, and request cancellation.
- Rewrite selected text in supported editors without copying the result back manually.
- Quick Actions for summaries, key points, simpler wording, translation, and image descriptions, plus your own saved prompts.
- Drag and drop PDFs, text and code files, RTF documents, EML email files, images, and web URLs into the assistant.
- Capture another application's window and ask about the screenshot with a provider that supports images.
- Standard, Gradient, and Glass themes, with selectable Liquid Glass styles.

Attachment support depends on the provider. See [current limits](#current-limits) before using images or videos.

## Requirements and installation

The current source targets **macOS 27 or later**. Apple's on-device model requires an Apple Intelligence-capable Mac with Apple Intelligence enabled and its model assets ready. Local MLX requires an Apple silicon Mac and the optional runtime described below.

1. Download the app from the [Releases page](https://github.com/Joaov41/Aiassistant/releases/latest). For the v2.0.1 DMG, open it and copy Aiassistant to Applications.
2. Launch the app. Its **AI** menu-bar item provides Settings and the MLX server controls.
3. Grant **Accessibility** permission in System Settings → Privacy & Security → Accessibility for global activation, selected-text capture, and inline replacement.
4. Grant **Screen Recording** permission when you want to capture application windows.
5. Open Settings and choose an AI provider.

The [v2.0.1 public DMG](https://github.com/Joaov41/Aiassistant/releases/tag/v2.0.1) is a notarized and stapled Developer ID build. Its release notes state that Private Cloud Compute is unavailable in that distributed build. Native PCC support in the source requires an appropriately signed build, as explained below.

Python and Homebrew are only needed for the optional Local MLX runtime.

## Using the app

| Action | Control |
| --- | --- |
| Open or close the main assistant popup | Quickly double-tap **Left Shift** |
| Open Quick Actions | Quickly triple-tap **Left Shift** |
| Choose a provider or change appearance | AI menu-bar item → Settings |
| Start or stop the app-managed MLX servers | AI menu-bar item → Start MLX Servers / Stop MLX Servers |

To work with text, select it in another app before opening the assistant. Use **Chat** to discuss the selection, or **Rewrite** to enter an instruction such as "Make this email clearer" and replace the original selection.

Quick Actions opened with triple-tap use inline replacement for text actions. You can also choose saved prompts from Rewrite mode.

For documents and images, drag an attachment into the popup. Use **Capture Window** to select a visible application window. **New Chat** clears the current conversation and context; **Copy** copies the conversation.

PDF import uses PDFKit text extraction, with Apple Vision OCR for pages that have no embedded text. EML import extracts email content for use as context.

Inline replacement depends on the target editor's Accessibility and paste support. The app checks the captured target before pasting and avoids inserting responses marked as incomplete.

## AI providers

The names below match the provider picker in Settings.

| Setting | Provider | Setup |
| --- | --- | --- |
| Local | Apple's on-device Foundation Model | Enable Apple Intelligence and wait for the model assets to be ready |
| Apple Cloud | Apple Private Cloud Compute through FoundationModels | Internet access, an available PCC model, and Apple's managed entitlement in the app's signing profile |
| Local MLX | Gemma through local MLX text and vision servers | Install the optional Python runtime, choose a model, and start the servers from the menu bar |
| Local OpenAI | Your own OpenAI-compatible endpoint | Start your server and configure its base URL and model ID |

### Native Private Cloud Compute

Apple Cloud uses `PrivateCloudComputeLanguageModel()` and `LanguageModelSession` directly through Apple's **FoundationModels** framework.

It requires the managed entitlement:

```text
com.apple.developer.private-cloud-compute
```

The app checks the entitlement in its running signature with `SecTaskCopyValueForEntitlement`, then checks model availability. Adding the key to an entitlements file alone does not grant PCC access: the signing profile must include Apple's approval for that entitlement.

Still-image attachments are supported when the PCC model reports the `.vision` capability. Availability and signing errors are shown in Settings or in the response.

### Privacy and fallback behavior

On-device Apple inference and MLX inference run on your Mac. **Both providers can fall back to Apple Cloud when a request exceeds the local model's context limit.** That fallback uses the same native PCC provider and requires its entitlement and availability checks to pass.

The response includes a cloud-fallback notice and identifies the provider that answered. Selecting Local or Local MLX does not currently enforce a local-only policy; there is no privacy-policy switch in Settings.

Local OpenAI sends context to the endpoint you configure and has no PCC fallback. Use a server on this Mac for on-device processing. A remote base URL sends requests to that remote server.

Opening a web URL fetches that page over the network. MLX may also need internet access to download model weights before local inference can run.

## Optional Local MLX setup

Local MLX serves Gemma through separate Python text and vision runtimes. It is separate from Apple's on-device and PCC providers.

### Install the runtime

From a checkout of this repository, with Homebrew installed:

```sh
brew install python@3.12
bash script/setup_mlx_runtime.sh
```

The setup script uses `/opt/homebrew/bin/python3.12` by default. If Python 3.12 is installed elsewhere, supply its path:

```sh
PYTHON_BIN="/path/to/python3.12" bash script/setup_mlx_runtime.sh
```

The script recreates these virtual environments and installs the pinned package versions defined in [setup_mlx_runtime.sh](script/setup_mlx_runtime.sh):

- `~/Library/Application Support/Aiassistant/mlx-venv` for `mlx_lm.server`.
- `~/Library/Application Support/Aiassistant/mlx-vlm-venv` for `mlx_vlm.server`.

Check the installed commands:

```sh
"$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/mlx_lm.server" --help
"$HOME/Library/Application Support/Aiassistant/mlx-vlm-venv/bin/mlx_vlm.server" --help
```

### Choose a model and start the servers

1. Open Settings → **Local MLX**.
2. Choose a Gemma model. **12B** is the default.
3. Choose **Start MLX Servers** from the AI menu-bar item.
4. Wait for the model to download or load, then send your request.

Selecting Local MLX or sending a request does **not** automatically start the servers. Use **Stop MLX Servers** to stop processes launched by the app. After changing models, choose Start MLX Servers again so the launcher can load the new selection.

The first start may download weights from Hugging Face. Larger models need more memory and take longer to load.

| Model picker label | Text model repository |
| --- | --- |
| Small E2B | `mlx-community/gemma-4-e2b-it-4bit` |
| Small 4B | `mlx-community/gemma-4-e4b-it-4bit` |
| 12B | `mlx-community/gemma-4-12B-it-4bit` |
| 31B | `mlx-community/gemma-4-31b-it-4bit` |

Small 4B uses the E4B vision server for both text and images. The other selections use their selected text model plus `mlx-community/gemma-4-E2B-it-qat-4bit` for images. An existing E2B snapshot may be used in place of its repository ID.

The text endpoint is `http://127.0.0.1:8080/v1`; the vision endpoint is `http://127.0.0.1:8081/v1`. These ports must be available, or already served by the appropriate model.

If a model requires Hugging Face authentication, save the token where the app's launcher expects it:

```sh
mkdir -p "$HOME/Library/Application Support/Aiassistant/huggingface-token"
HF_TOKEN_PATH="$HOME/Library/Application Support/Aiassistant/huggingface-token/token" \
  "$HOME/Library/Application Support/Aiassistant/mlx-venv/bin/hf" auth login
```

### Troubleshooting MLX

If the app reports that a local server is unreachable, first check that you started it from the menu bar and installed the runtime. Inspect the logs for missing commands, package errors, model-download failures, or insufficient memory:

```sh
tail -n 160 /tmp/aiassistant-mlx-launcher.log
tail -n 160 /tmp/aiassistant-mlx-server.log
tail -n 160 /tmp/aiassistant-mlx-vlm-server.log
```

The launcher can time out while a large model is downloading or loading. Check the logs and retry after the model is ready.

## Connecting an OpenAI-compatible server

Start your server yourself; AI Assistant does not launch it.

In Settings → **Local OpenAI**:

1. Set the **Base URL**, including any API prefix your server requires. The default is `http://127.0.0.1:8080/v1`.
2. Enter an **API Key** if your server requires one. The app stores this credential in macOS Keychain.
3. Choose **Test & Load Models** to query the server's `/models` endpoint, then select a model or enter its ID manually.
4. Set **Max Output Tokens** for the response length. **Disable Model Thinking** sends `enable_thinking=false` through chat-template arguments to servers that support it.

Requests use the OpenAI-compatible `/chat/completions` API. Image inputs require a compatible vision model on the server.

## Current limits

- The on-device Apple provider currently processes text only; attached images are not analyzed by that provider.
- PCC image understanding depends on the model reporting vision capability. Local MLX and Local OpenAI image support depends on the loaded model.
- Video files can be imported, but none of the current providers implements video analysis.
- Conversations are held in memory, with no saved chat library or restoration after relaunch. Use Copy to keep a conversation.
- Routing currently consists of provider selection and the context-limit PCC fallback described above.

## Building from source

Use a Mac with Xcode and the macOS 27 SDK.

```sh
git clone https://github.com/Joaov41/Aiassistant.git
cd Aiassistant
open Aiassistant.xcodeproj
```

Let Xcode resolve the Swift package dependencies, then select the **Aiassistant** scheme.

The checked-in project uses manual Apple Development signing and a PCC development provisioning profile. Configure your own development team, signing identity, and provisioning profile before building. PCC requires a profile approved for `com.apple.developer.private-cloud-compute`. For a build without PCC, remove that entitlement from the signing configuration and use an appropriate profile for your team.

Once signing is configured, build and run from Xcode or use:

```sh
bash script/build_and_run.sh
```

The helper builds the Debug app and launches it with Settings open.

## Project structure

- `Aiassistant/` contains the SwiftUI and AppKit app, provider implementations, Accessibility integration, attachment importers, and window management.
- `AiassistantTests/` and `AiassistantUITests/` contain the test targets.
- `Aiassistant.xcodeproj/` contains the Xcode project and package resolution.
- `script/` contains the build/run helper and optional MLX runtime setup.

## License

This project is released under the [MIT License](LICENSE). You may share and modify it, but copies or substantial portions must keep the copyright notice for John Val.

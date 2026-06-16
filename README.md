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

## Notarized Build

Per request from people who cannot compile the app locally, a notarized macOS build is available on the [Releases page](https://github.com/Joaov41/Aiassistant/releases/latest).

## Apple PCC Note

When using Apple PCC, Terminal may appear in the Dock while the app routes the request through Apple's `fm` command-line tool. See Apple's [Build AI-powered scripts with the fm CLI and Python SDK](https://developer.apple.com/videos/play/wwdc2026/334/) session for more about `fm`.

## License

This project is released under the [MIT License](LICENSE). You may share and modify it, but copies or substantial portions must keep the copyright notice for John Val.

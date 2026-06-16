# GPT-OSS

OpenAI's GPT-OSS models for on-device inference via Core AI.

## Supported Models

| Model       | Parameters | macOS | iOS |
| ----------- | ---------- | ----- | --- |
| GPT-OSS 20B | 20B        | Yes   | No  |

## Setup to export models

If you haven't installed `uv`, install it by
```bash
brew install uv
```
## Export models

```bash
# Defaults to macOS variant
uv run coreai.llm.export openai/gpt-oss-20b
```

> **Note:** GPT-OSS ships with pre-quantized MXFP4 weights. The registry preset uses `--compression none` (no additional quantization needed).

**Options:**

```bash
# Custom output directory
uv run coreai.llm.export openai/gpt-oss-20b --output-dir ./my-models/

# Preview resolved config without exporting
uv run coreai.llm.export openai/gpt-oss-20b --dry-run
```

## Run a Core AI Language Model

### In your iOS and macOS applications via Foundation Models

```swift
import FoundationModels
import CoreAILanguageModels

let model = try await CoreAILanguageModel(resourcesAt: modelURL)

let session = LanguageModelSession(model: model)

let response = try await session.respond(to: "What is quantum computing?")

print(response)
```

### On your Mac using built-in Command Line Tool

```bash
swift run -c release llm-runner --model path/to/exported_model_folder --prompt "Hello"
```

## Benchmark a Core AI Language Model

```bash
swift run -c release llm-benchmark --model path/to/exported_model_folder
```

Defaults: 512 prompt tokens, 1024 generation tokens, 5 trials. Override with `-p`, `-g`, and `-n`.

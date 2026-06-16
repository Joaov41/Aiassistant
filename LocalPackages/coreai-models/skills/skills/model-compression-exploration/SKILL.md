---
name: model-compression-exploration
description: Systematically explore weight compression configurations (quantization and palettization) for a PyTorch model using coreai-opt, presenting a comprehensive overview of accuracy-vs-size tradeoff options. Use this skill whenever the user wants to compress a model, explore quantization or palettization options, understand compression config tradeoffs, reduce model size, or compare different compression techniques. Also trigger when the user mentions coreai-opt compression, weight quantization exploration, or palettization exploration — even if they don't say "explore" explicitly.
---

# Model Compression Exploration

Systematically explore weight-only compression configurations for a PyTorch model using `coreai_opt`. The goal is to present the user with a clear overview of accuracy-vs-size tradeoff options across quantization and palettization, organized into three experiment groups.

## Supporting files

| File | Contents |
| --------------------------------------------------------------- | ------------------------------------------------------ |
| [`compression_patterns.md`](references/compression_patterns.md) | Empirical patterns: what works, what doesn't, and why |
| [`size_estimation.md`](references/size_estimation.md) | How to compute theoretical compressed model size |
| [`experiment_runner.md`](references/experiment_runner.md) | Memory-safe experiment loop, helpers, average bitwidth |
| [`output_report.md`](references/output_report.md) | How to format and organize the output produced |

## Bundled scripts

The deterministic helpers are unit-tested and importable. Prefer them over hand-rolled equivalents — they encode formulas and edge cases that have already been debugged.

| Script | Purpose |
| ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| [`scripts/compression_metrics.py`](scripts/compression_metrics.py) | Theoretical size, average bitwidth, divisibility, parametrize walk |
| [`scripts/quality_metrics.py`](scripts/quality_metrics.py) | PSNR / SNR / IoU and a per-output dispatcher |

## CoreAI Opt

CoreAI Opt (coreai-opt) is a package that helps with model compression and model optimization in a hardware-aware manner.

For the full coreai-opt documentation, fetch:
`https://apple.github.io/coreai-optimization/llms-full.txt`

Check to see that the package is installed in the current python scope (venv, conda env). The package is called `coreai-opt` and is imported as `coreai_opt`. If it is not installed, prompt the user to install it.

For API verification at runtime, use `help(coreai_opt)` or `inspect` to confirm current signatures.

______________________________________________________________________

## Setup

### Step 1: Gathering input from user

The user has to provide information on how to load the model, how to perform a forward pass, what are the inputs to be used and how to check the quality of the outputs. This information is very important to acquire from the user, since every model is different and making assumptions can lead us to meaningless results. For example, choosing to use random inputs instead of a valid input can result in the output quality being meaningless.

1. **Model**: `get_model() -> nn.Module` - How to load/create the model (imports, weights, model class).
2. **Data**: `get_reference_data() -> tuple[torch.Tensor, ...] | dict[str, torch.Tensor]` - A representative batch of real inputs. Even 1-3 real samples suffice — random inputs produce meaningless PSNR because they don't exercise learned weight structure.
3. **Forward pass**: verify that `get_model()(*get_reference_data())` (or the dict-spread equivalent `get_model()(**get_reference_data())`) actually runs. If neither works, ask the user how to invoke the model end-to-end.
4. **Quality Metric**: `get_quality_metric(model_out) -> list[str]` - we need to understand what metric to use for checking the quality of each output against the uncompressed output. Ask the user for each output produced by the model, should we use one of {"psnr", "snr", "iou"}. For example, if we have a mask as an output, PSNR isn't the right metric. IoU is a right metric.

This information is required to proceed to the next step.

### Step 2: Check the setup

- Compute the **uncompressed baseline output** (store as detached tensor) and the **uncompressed baseline size** (total parameters × 2 bytes, assuming fp16 storage). The bundled `_call_model` helper in `references/experiment_runner.md` handles both tuple- and dict-shaped reference data; reuse it everywhere you call the model.

### Step 3: Estimate the time it takes for doing our compression exploration

1. Take the default global weight quantization preset `QuantizerConfig.presets.w8()` (graph mode is the default). Apply it to a fresh model and time a single forward pass through the prepared model. **If `Quantizer.prepare(...)` errors** — e.g., `torch.export` guard failure, dynamic control flow — fall back to `QuantizerConfig.presets.w8(execution_mode=ExecutionMode.EAGER)` and time again. The mode that succeeded here is the mode you should use for the entire sweep, so the timing reflects real wall-clock cost. Record this mode and reuse it.

   The single elapsed time becomes `avg_quant_time`. Pass `quantizer=quantizer` to `extract_layer_specs(...)` so it can read graph-mode FQ metadata via `Quantizer._get_fake_quantize_modules()`; otherwise the walker won't see graph-mode quantization and would misreport every layer as fp16.

2. Take the default palettization preset `KMeansPalettizerConfig.presets.w6()` (6-bit, per-grouped-channel, group_size=16). Apply the palettization config and run a forward pass while calculating the time it takes to compute a palettized model pass. This will be the average time it takes to run a single palettization pass: `avg_palett_time`. Palettization is eager-only — there's no graph/eager fallback to do here.

3. Below, we enumerate 3 groups of config options, totaling around ~15 quant configs and ~15 palett configs. Estimate the time required as `avg_quant_time * 15 + avg_palett_time * 15`.

4. Ask the user if this time estimate is in-line with their expectation before proceeding. Use the AskUserQuestion tool here to provide the estimate and ask if it is okay to proceed, or if they want to cut short the time.

______________________________________________________________________

## Step 4: Experimentation

### How to run each experiment

Use `coreai_opt.quantization.Quantizer` for Groups 1-2 and `coreai_opt.palettization.KMeansPalettizer` for Group 3. Run the loop in `references/experiment_runner.md` (memory-safe, plus the canonical `extract_layer_specs(prepared, quantizer=compressor)` pattern that works in both modes). The execution mode was decided once in Step 3 — use that mode for every config in the sweep.

For each config:

1. Re-create a fresh model
2. Apply compression via `prepare()` by loading the config
3. Compute theoretical size, average bitwidth and compression ratio using `references/size_estimation.md`
4. Run a forward pass on the prepared model in `eval()` mode with `no_grad`
5. Compute the per-output quality metrics chosen by the user
6. Append the record to `results.jsonl` (Output Report section)
7. Free memory (template handles this)
8. Do not call `finalize()`. Calibration is not needed for weight-only compression.

### What are the experiments to run

Build configs through `QuantizerConfig.presets` / `KMeansPalettizerConfig.presets` where the shape matches; for the variations they don't cover (asymmetric, symmetric_with_clipping, alternative block sizes, `enable_per_channel_scale=True`), see `references/experiment_runner.md` for the spec-construction patterns. Verify the preset namespace at runtime with `dir(QuantizerConfig.presets)` and `dir(KMeansPalettizerConfig.presets)` — new presets are added over time.

#### 1a: Channel-structured quantization — 6 configs

Cross-product of `{int8, int4} × {symmetric, asymmetric, symmetric_with_clipping}`, all per-channel. The two `symmetric` corners match `QuantizerConfig.presets.w8()` and `.w4()` directly; the other four are variations that swap `qscheme=`.

#### 1b: Block-structured quantization — 9 configs

Cross-product of `{block_size: 16, 32, 128} × {symmetric, asymmetric, symmetric_with_clipping}`, all int4 per-block. The `block_size=32, symmetric` corner matches `QuantizerConfig.presets.w4_per_block(block_size=32)`; the rest swap `block_size=` and `qscheme=`.

**Scale overhead reminder**: per-block stores one fp16 scale per block. At `block_size=16` with int4, effective bitwidth is ~5 bits/weight — account for this in `compute_average_bitwidth` (it already does).

#### 2: Palettization — 15 configs

Cross-product of `{(8-bit, per-tensor), (6-bit, per-tensor), (6-bit, gs=4|8|16), (4-bit, gs=4|8|16)} × {enable_per_channel_scale: True, False}` minus the one undefined entry (8-bit per-tensor with `enable_per_channel_scale=True` is sometimes folded into the 8-bit per-tensor row — keep both for completeness, totaling 15). The `(8-bit, per-tensor, False)` corner matches `KMeansPalettizerConfig.presets.w8()`; `(6-bit, gs=16, False)` matches `presets.w6()`; `(4-bit, gs=16, False)` matches `presets.w4()`.

#### Per-Group Refinement

After the main sweep within a group:

1. **Filter** — drop configs that errored or scored below the floor (PSNR < 10 dB or IoU < 0.1). These are too far gone for layer-skipping to rescue.
2. **Pick two refinement seeds** per group:
   - **95th-percentile config** — best surviving quality, modest size win. Refining this tells us how much smaller we can go without losing quality.
   - **75th-percentile config** — mid-quality, larger size win. Refining this tells us how much quality we can recover at an aggressive compression target.
3. **Run 5 layer-skip variants per seed** (10 extra runs/group):
   - Skip first layer
   - Skip last layer
   - Skip first **and** last layer
   - Skip all layers of the smallest-aggregate-parameter type, breaking ties by Embedding > Linear > Conv. Compute parameter counts per type and pick the type with the smallest sum so compression ratio barely moves.
   - Skip first/last **and** the smallest-parameter type — the safest combination.
4. **Apply skips via `set_module_name` overrides** on top of the seed's preset. Refinement runs **inherit** any divisibility overrides from the seed — don't rebuild the config from scratch.
5. **Sub-models** — for multi-modal architectures (ViT backbone + text encoder feeding an encoder-decoder), use `model.named_children()` to enumerate top-level submodules. Boundary layers exist *within* each submodule; the "first/last layer" skip should consider entry/exit projections of each major child, not only the outermost first/last of the whole model.

______________________________________________________________________

## Output Report

Use a JSON structure to track all the details of the experiment. We want to track the following:

```json
{
  "group": "2",
  "config": {
    "name": "palette_grouped_gs4_6bit_pcs0_skip-Embedding",
    "path": "path/to/config",
  },
  "time_taken": 1000,
  "output_quality_metrics": [
    {"name": "bbox", "metric": "iou", "value": 0.7},
    {"name": "logits", "metric": "psnr", "value": 16}
  ],
  "compression_metrics": {
    "average_bitwidth": 5,
    "compression_ratio": 1.7,
    "theoretical_model_size": 402
  }
}
```

After all sweeps complete, the JSONL holds 40-50 records — too many to surface to the user verbatim. **For each group, pick exactly 5 configs that span the accuracy-vs-size tradeoff** and put only those in the report. Concretely, after filtering out configs that errored or fell below the floor (PSNR < 10 dB / IoU < 0.1):

1. **Highest quality** — best primary-metric value in the group.
2. **Highest compression** — best compression ratio in the group (after the floor filter).
3. **Three points on the frontier between (1) and (2)** — pick configs that maximize spread, not similarity. A simple rule: sort survivors by compression ratio, then take the configs whose `(quality, ratio)` points are furthest from the line connecting (1) and (2). If two configs have nearly identical `(quality, ratio)`, prefer the one with the simpler config (fewer overrides, larger block/group size).

The goal is that a reader scanning the table can see the *shape* of the tradeoff in one glance: not 30 indistinguishable rows, but 5 anchors covering the frontier from "barely compressed, near-perfect quality" to "maximum compression, quality at the floor". If a group has fewer than 5 survivors, surface them all and note the count.

Produce one report per group with these columns:

| Config | PSNR (dB) | Avg Bitwidth | Compression Ratio |
| ------ | --------- | ------------ | ----------------- |

Refer to `references/output_report.md` for more details on output formatting. Following this format consistently keeps the qualitative picture comparable across runs; consumers grep these tables to compare model variants.

Generate a PSNR-vs-compression-ratio scatter plot (matplotlib) with annotated config names. Save as `compression_exploration.png` and include the link in the report.

______________________________________________________________________

## Parallelization

The full sweep is ~30 main-sweep configs + ~30 refinement configs × per-config-time. Launch one subagent per group (1a, 1b, 2) so they run in parallel:

- Agent "group-1a runner" → channel-structured quant (6 configs) + its 10 refinement runs
- Agent "group-1b runner" → block-structured quant (9 configs) + its 10 refinement runs
- Agent "group-2 runner" → palettization (15 configs) + its 10 refinement runs

Each agent appends to a shared `results.jsonl` file (one JSON record per line). JSONL append is safe in practice when each agent writes one complete line at a time — use a flush after each write. The main agent uses `/loop 5m` (a slash command in this repo's plugin set that re-runs a prompt on a schedule) to read `results.jsonl` and report per-group `completed/total` to the user. Long sweeps look hung without progress signals; surface counts so the user can ctrl-C if something is clearly broken.

See `references/experiment_runner.md` for the `append_record()` and `status_snapshot()` helpers.

______________________________________________________________________

## Common Pitfalls

Read `references/compression_patterns.md` for the full list. Critical ones:

1. **Silent skip on indivisible block/group size**: Per-block and per-grouped-channel silently skip layers where the weight dimension isn't divisible. Pre-check with `check_divisibility()` and override with per-channel.
2. **Graph mode failures**: covered by the dry-run probe in Step 3 — fall back to `execution_mode=ExecutionMode.EAGER` for the whole sweep. Always pass `quantizer=` to `extract_layer_specs(...)` so it works in either mode.
3. **Axis defaults**: coreai-opt picks the correct default axis per module type. Only override for non-standard behavior.
4. **Scale/ZP overhead**: At 2-4 bit with fine granularity, overhead can be 5-15% of total size.
5. **LUT overhead**: 8-bit per-channel stores 256 × fp16 entries per output channel — significant for wide layers.

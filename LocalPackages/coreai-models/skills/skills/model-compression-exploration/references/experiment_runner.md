# Memory-Safe Experiment Runner

The deterministic helpers (size, quality metrics, divisibility) live in `scripts/`:

- `scripts/compression_metrics.py` — `LayerSpec`, `compute_compressed_size_mb`, `compute_average_bitwidth`, `check_divisibility`, `extract_layer_specs`, `fp16_baseline_mb`, `compression_ratio`
- `scripts/quality_metrics.py` — `psnr`, `snr`, `iou`, `compute_quality_metrics`

This document describes how to wire them into a sweep.

## Memory Management Rules

Never hold more than **two model instances** at once: the baseline (for reference output) and the current experiment. Between experiments:

1. Rebind the prepared model and quantizer/palettizer objects to `None`
2. `gc.collect()` and `torch.cuda.empty_cache()` (if CUDA)
3. Re-create the model from scratch for the next config

For very large models where even two copies strain memory, compute the baseline output once, store it as a detached tensor, then delete the baseline model before starting experiments.

______________________________________________________________________

## Experiment Loop Template

```python
import gc
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

import torch

from compression_metrics import (
    compute_average_bitwidth,
    compute_compressed_size_mb,
    compression_ratio,
    extract_layer_specs,
    fp16_baseline_mb,
)
from quality_metrics import compute_quality_metrics


@dataclass
class ExperimentResult:
    config_name: str
    group: str
    metrics: list[dict] = field(default_factory=list)  # [{"name","metric","value"}]
    size_mb: float = 0.0
    avg_bitwidth: float = 0.0
    compression_ratio: float = 0.0
    duration_ms: float = 0.0
    error: Optional[str] = None


def _call_model(model, data):
    """Handle both tuple and dict reference data."""
    return model(*data) if isinstance(data, tuple) else model(**data)


def run_compression_experiments(
    get_model: Callable[[], torch.nn.Module],
    get_reference_data: Callable,
    metric_per_output: list[str],
    configs: list[dict],
):
    """Run a sweep with proper memory management.

    Args:
        get_model: Returns a fresh ``nn.Module`` each call.
        get_reference_data: Returns the reference inputs (tuple or dict).
        metric_per_output: One of {"psnr", "snr", "iou"} per output.
        configs: List of dicts with keys "name", "group", "apply".
            ``apply(model, data) -> (prepared_model, compressor)`` constructs
            the prepared model AND returns the compressor instance
            (``Quantizer`` or ``KMeansPalettizer``) so we can hand it to
            ``extract_layer_specs(prepared, quantizer=compressor)`` — that
            kwarg is what makes graph mode work. Use
            ``QuantizerConfig.presets.*`` and ``KMeansPalettizerConfig.presets.*``
            (with ``set_module_name`` / ``set_module_type`` overrides as
            needed) to build the config.

    Returns:
        List of ExperimentResult.
    """
    # Compute baseline once and discard the baseline model.
    base_model = get_model().eval()
    fp16_mb = fp16_baseline_mb(base_model)
    data = get_reference_data()
    with torch.no_grad():
        baseline_output = _detach_all(_call_model(base_model, data))
    del base_model
    gc.collect()

    results: list[ExperimentResult] = []

    for cfg in configs:
        prepared = compressor = model = None
        try:
            model = get_model().eval()
            t0 = time.perf_counter()
            prepared, compressor = cfg["apply"](model, data)
            prepared.eval()
            with torch.no_grad():
                output = _call_model(prepared, data)
            duration_ms = (time.perf_counter() - t0) * 1000

            # Pass quantizer=compressor regardless of type. extract_layer_specs
            # uses _get_fake_quantize_modules() if available (graph + eager
            # quantization) and otherwise falls back to walking parametrize
            # (palettization).
            specs = extract_layer_specs(prepared, quantizer=compressor)
            size_mb = compute_compressed_size_mb(specs)
            avg_bw = compute_average_bitwidth(specs)
            metrics = compute_quality_metrics(
                output, baseline_output, metric_per_output
            )

            results.append(
                ExperimentResult(
                    config_name=cfg["name"],
                    group=cfg["group"],
                    metrics=metrics,
                    size_mb=size_mb,
                    avg_bitwidth=avg_bw,
                    compression_ratio=compression_ratio(fp16_mb, size_mb),
                    duration_ms=duration_ms,
                )
            )

        except Exception as e:
            results.append(
                ExperimentResult(
                    config_name=cfg["name"],
                    group=cfg["group"],
                    error=f"{type(e).__name__}: {e}",
                )
            )

        finally:
            prepared = compressor = model = None
            gc.collect()
            if torch.cuda.is_available():
                torch.cuda.empty_cache()

    return results


def _detach_all(out):
    if isinstance(out, torch.Tensor):
        return out.detach().clone()
    if isinstance(out, dict):
        return {k: v.detach().clone() for k, v in out.items()}
    if isinstance(out, tuple):
        return tuple(v.detach().clone() for v in out)
    return [v.detach().clone() for v in out]
```

______________________________________________________________________

## Building Configs from Presets

Use coreai-opt's preset namespaces as the starting point — never build `QuantizationSpec`/`PalettizationSpec` from scratch when a preset matches:

```python
from coreai_opt.quantization.config.quantization_config import (
    ModuleQuantizerConfig,
    QuantizerConfig,
)
from coreai_opt.palettization.config.palettization_config import (
    KMeansPalettizerConfig,
    ModuleKMeansPalettizerConfig,
)

# Direct preset (graph mode is the default; pass execution_mode=ExecutionMode.EAGER
# only if Step 3's dry-run probe forced you into eager)
qcfg = QuantizerConfig.presets.w4_per_block(block_size=32)

# Preset + per-layer override (e.g. for divisibility-incompatible layers)
qcfg.set_module_name("classifier.fc", ModuleQuantizerConfig.presets.w4())

# Preset + module-type override (e.g. keep all Embeddings at int8)
import torch.nn as nn

qcfg.set_module_type(nn.Embedding, ModuleQuantizerConfig.presets.w8())

# Apply: Quantizer takes (model, cfg); .prepare(data) runs calibration data
# through it. The constructor signature is (model, config), not (config) —
# don't reverse them.
quantizer = Quantizer(model, qcfg)
prepared = quantizer.prepare(data)

# Extract layer specs — pass quantizer= so we can use _get_fake_quantize_modules,
# which works for both graph and eager modes.
specs = extract_layer_specs(prepared, quantizer=quantizer)
```

**Mode strategy**: graph mode is the preset default and gives better wall-time on most models. If `Quantizer.prepare(...)` errors with `torch.export` guard failures or dynamic-control-flow issues, fall back to `execution_mode=ExecutionMode.EAGER` and use eager for the rest of the sweep. The Step 3 timing dry-run in SKILL.md is the right place to make this decision once.

For sweep variations the presets don't cover (asymmetric, symmetric_with_clipping, alternative block sizes, `enable_per_channel_scale=True`), construct a `QuantizationSpec` / `PalettizationSpec` directly. Verify field names at runtime via `inspect.signature(QuantizationSpec.__init__)` — coreai-opt is the source of truth.

______________________________________________________________________

## Divisibility Pre-Check

Run this before applying per-block quantization or per-grouped-channel palettization to identify layers that will be silently skipped:

```python
from compression_metrics import check_divisibility

incompatible = check_divisibility(model, axis=1, block_size=32)
if incompatible:
    print(f"WARNING: {len(incompatible)} layers are not divisible — overriding:")
    for name, (dim, bs) in incompatible.items():
        print(f"  {name}: shape[axis]={dim}, block_size={bs}")
        qcfg.set_module_name(name, ModuleQuantizerConfig.presets.w4())  # per-channel
```

______________________________________________________________________

## Results Table Helper

```python
def print_results_table(results: list[ExperimentResult], baseline_size_mb: float):
    """Print a formatted comparison table sorted by primary quality metric."""
    header = (
        f"{'Config':<32} | {'Quality':>9} | {'Size (MB)':>9} | "
        f"{'Bitwidth':>8} | {'Ratio':>7} | Notes"
    )
    print(header)
    print("-" * len(header))
    print(
        f"{'fp16 baseline':<32} | {'inf':>9} | {baseline_size_mb:>9.1f} | "
        f"{'16.00':>8} | {'1.0x':>7} |"
    )

    def primary(r):
        return r.metrics[0]["value"] if r.metrics else 0.0

    for r in sorted(results, key=lambda x: -primary(x)):
        if r.error:
            print(
                f"{r.config_name:<32} | {'ERROR':>9} | {'-':>9} | "
                f"{'-':>8} | {'-':>7} | {r.error[:40]}"
            )
        else:
            print(
                f"{r.config_name:<32} | {primary(r):>9.2f} | {r.size_mb:>9.1f} | "
                f"{r.avg_bitwidth:>8.2f} | {r.compression_ratio:>6.1f}x |"
            )
```

______________________________________________________________________

## JSONL append + status snapshot

Per the Parallelization section in SKILL.md, every per-group runner appends to a shared `results.jsonl`. Use these helpers verbatim — `append_record` enforces the single-`os.write` invariant that makes the append cross-process safe.

```python
import json
import os


def append_record(record: dict, path: str = "results.jsonl") -> None:
    """Append one JSON record to a JSONL file. Cross-process safe."""
    line = (json.dumps(record) + "\n").encode("utf-8")
    with open(path, "ab") as fh:
        fh.write(line)


def status_snapshot(path: str = "results.jsonl") -> dict:
    """Read the JSONL and return per-group completion counts for /loop 5m."""
    by_group: dict[str, list[str]] = {}
    if not os.path.exists(path):
        return {"completed": 0, "by_group": {}}
    with open(path) as fh:
        for line in fh:
            r = json.loads(line)
            by_group.setdefault(r["group"], []).append(r["config"]["name"])
    return {
        "completed": sum(len(v) for v in by_group.values()),
        "by_group": {g: len(v) for g, v in by_group.items()},
    }
```

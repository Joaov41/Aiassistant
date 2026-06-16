# Model Compression Size Estimation

The deterministic logic for size estimation, average bitwidth, and divisibility checks lives in `scripts/compression_metrics.py`. This document describes the formulas the script uses and how to call it.

## Quick usage

```python
from compression_metrics import (
    LayerSpec,
    compute_compressed_size_mb,
    compute_average_bitwidth,
    compression_ratio,
    fp16_baseline_mb,
    check_divisibility,
    extract_layer_specs,
)

# 1) Baseline
fp16_mb = fp16_baseline_mb(model)

# 2) Pre-flight: detect layers that would be silently skipped
bad = check_divisibility(model, axis=1, block_size=32)
if bad:
    print(f"Layers needing per-channel override: {list(bad)}")

# 3) After prepare(), inspect the prepared model.
# Quantizer takes (model, cfg); .prepare(data) runs calibration data
# through it. Pass quantizer= to extract_layer_specs so it works for
# both graph-mode and eager-mode prepared models (it uses
# Quantizer._get_fake_quantize_modules() under the hood).
quantizer = Quantizer(model, cfg)
prepared = quantizer.prepare(data)
specs = extract_layer_specs(prepared, quantizer=quantizer)
size_mb = compute_compressed_size_mb(specs)
avg_bits = compute_average_bitwidth(specs)
ratio = compression_ratio(fp16_mb, size_mb)
```

For palettization, the equivalent shape is:

```python
palettizer = KMeansPalettizer(model, palett_cfg)
prepared = palettizer.prepare(data)
specs = extract_layer_specs(prepared)  # palettization is eager-only;
# no quantizer= kwarg needed
```

## Size formulas (what the script computes)

All floating-point values (scales, uncompressed weights, biases) are stored in **fp16** (2 bytes per element).

### Quantized weight

```text
weight_bytes = numel * (n_bits / 8)
```

For int4: `numel * 0.5` bytes (2 values packed per byte). For int8: `numel * 1` byte.

### Scale and zero-point overhead

The number of scale/zero-point groups depends on granularity:

- **Per-tensor**: 1 group
- **Per-channel (axis=A)**: `weight.shape[A]` groups
- **Per-block (axis=A, block_size=B)**: `ceil(weight.shape[A] / B) × product(weight.shape[other_axes])`
  - For a 2D weight `[out, in]` with `axis=0, block_size=32`: `ceil(out/32) * in` groups
  - For `axis=1, block_size=32`: `out * ceil(in/32)` groups
- **Per-grouped-channel (axis=A, group_size=G)**: `ceil(weight.shape[A] / G)` groups

```text
scale_bytes      = n_groups * 2                    # fp16
zero_point_bytes = n_groups * (n_bits / 8)         # asymmetric only
```

For symmetric quantization, the zero-point is always 0 → `zero_point_bytes = 0`. For asymmetric, the ZP shares dtype with the quantized weight.

### Palettized weight

```text
index_bytes = numel * (n_bits / 8)                 # indices into the LUT
lut_bytes   = (2^n_bits) * n_luts * 2              # fp16 centroids
```

`n_luts` follows the same group calculation as scales above. With `enable_per_channel_scale=True`, add one fp16 scale per output channel.

### Uncompressed parameters

Biases, embedding tables, LayerNorm/BatchNorm parameters, and any layers excluded from compression are stored as fp16 — pass them via `extra_fp16_params` when calling `compute_compressed_size_mb`, or rely on `extract_layer_specs` reporting them as `n_bits=16` LayerSpecs (the helper handles either path).

### Total

```text
total_bytes = sum(weight_or_index_bytes)
            + sum(scale_bytes)
            + sum(zero_point_bytes)        # asymmetric only
            + sum(lut_bytes)               # palettization only
            + sum(per_channel_scale_bytes) # palettization toggle
            + sum(uncompressed_bytes)
total_mb    = total_bytes / (1024 * 1024)
```

## Average bitwidth

Weighted by parameter count:

```text
average_bitwidth = sum(numel_i * bits_i) / sum(numel_i)
```

Implemented in `compute_average_bitwidth`.

## Reporting

Always report both:

- **Absolute size** in MB (compressed and fp16 baseline)
- **Compression ratio** vs fp16 baseline: `fp16_mb / compressed_mb`

Example:

```text
Quantized layers:    53 (840.2M params) → 420.1 MB (int4)
  Scale overhead:    +12.3 MB
Unquantized layers:  7 (2.1M params) → 4.2 MB (fp16)
Total:              436.6 MB (3.85x compression vs 1681.0 MB fp16)
```

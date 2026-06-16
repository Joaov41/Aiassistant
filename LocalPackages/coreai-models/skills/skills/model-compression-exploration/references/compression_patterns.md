# Compression Patterns

Empirical patterns observed across ResNet50, SAM3, and other vision models. These guide the sweep order and help interpret results.

## Pattern 1: Granularity is the single biggest lever

Finer granularity consistently dominates across both quantization and palettization. Per-channel palettization can beat per-tensor by 30-40 dB PSNR. Per-channel quantization beats per-tensor by similar margins. The more independently each weight group can be represented, the better.

**Implication**: For quantization, start with per-channel granularity and only coarsen if size constraints demand it. For palettization, start with per-tensor (a single LUT per layer) as the baseline, then try per-grouped-channel to improve accuracy — finer granularity gives better results but adds LUT overhead.

## Pattern 2: Palettization beats quantization at equal bit widths — when granularity matches

At per-channel granularity, k-means centroids adapt to the actual weight distribution rather than imposing a uniform grid. This gives palettization a ~15-19 dB edge over quantization at both 8-bit and 4-bit. But at per-tensor granularity, palettization can be far worse — a single shared codebook across an entire layer can't compete with per-channel scales.

**Implication**: When exploring, always compare palettization per-channel against quantization per-channel at the same bit width. Don't compare per-tensor palettization against per-channel quantization — that's not a fair fight.

## Pattern 3: Boundary layers are disproportionately error-prone

Skipping the first and last few layers consistently improves PSNR — up to +9 dB. The last layers (classifier FC, output projections) typically matter more than the first. This is because:

- Classifier layers map to a large number of classes (narrow bottleneck, high sensitivity)
- Final feature extraction layers have the widest channels, making them hardest to compress
- Input layers see the rawest data with the most dynamic range

Boundary layers can also exist *within* submodules. A multi-modal model with a ViT image backbone and a text encoder feeding into a fusion transformer has boundary layers at the entry/exit of each backbone. Skip-list candidates aren't only the model's outermost first/last layers — also try the input/output projections of each major submodule (use `model.named_children()` to enumerate them).

**Implication**: Always try layer-skip ablations on the top configs. The size cost of leaving 1-2 layers uncompressed is usually small relative to the quality gain.

## Pattern 4: Asymmetric > symmetric, scaling with compression

At 8-bit the difference is modest (~1.5 dB). At 4-bit, asymmetric can gain +3-5 dB over symmetric. Lower bit widths have fewer representable values, so the extra zero-point degree of freedom matters more.

### Pattern 4b: `symmetric_with_clipping` is often a big quality lever — especially at low bits

`symmetric_with_clipping` clips the quantization range to equal bins on either side of zero (e.g., int4: [-7, 7] instead of [-8, 7]). This prevents a single outlier from inflating the scale and wasting a bin. SAM3 benchmarks showed +7.3 dB improvement over plain `symmetric` at int4. The effect varies by model and bit-width — small models or 8-bit configs may see negligible gain — and is most pronounced at low bit widths and small block sizes (block_size ≤ 32), where each bin represents a larger fraction of the range.

**Implication**: Include both `symmetric` and `symmetric_with_clipping` in every int4 sweep. The difference is often larger than the difference between granularity levels.

## Pattern 5: This skill is weight-only

Activation quantization (W8A8) is out of scope. If a downstream user needs W8A8 for latency, expect an additional ~6-8 dB drop on top of the weight-only numbers reported here.

## Pattern 6: Block granularity has a non-obvious sweet spot

For quantization, block-32 + asymmetric can beat per-channel because more scale parameters compensate for smaller blocks. But for palettization, per-channel (group_size=1) always wins because k-means benefits from seeing all weights in a channel together. At very low bits (4-bit palettization), small group sizes can actually hurt — too few weights per group for the centroids to cluster meaningfully.

**Implication**: Try block-32 for quantization (it may surprise you). For palettization, start with per-channel and only increase group_size if compute time is prohibitive.

## Pattern 7: Silent validation failures are the #1 debugging pitfall

Per-block quantization and per-grouped-channel palettization silently skip layers where the weight dimension isn't divisible by the block/group size. The model runs fine, but those layers remain uncompressed — and the theoretical size calculation won't match expectations.

**How to detect**: Use the bundled helper before applying a config:

```python
from compression_metrics import check_divisibility

incompatible = check_divisibility(model, axis, block_size)
# returns {module_name: (offending_dim, block_size), ...}
```

**How to fix**: Use `qcfg.set_module_name(name, ModuleQuantizerConfig.presets.w4())` (or the palettization equivalent) to override those specific layers with per-channel granularity.

## Pattern 8: Graph mode is the default; eager is the fallback

Graph mode (`ExecutionMode.GRAPH`) uses `torch.export` to trace the model into an FX graph, enabling automatic op fusion and deduplication of fake-quant nodes. It fails on:

- Dynamic control flow (if/else depending on input values)
- Mixed tensor shapes in attention (e.g., window vs global attention)
- Custom ops not supported by `torch.export`

For weight-only PTQ exploration the quality difference between modes is negligible — both produce the same fake-quantized weights. SKILL.md Step 3 picks the mode once via a dry-run; the rest of the sweep stays on the chosen mode. Always pass `quantizer=` to `extract_layer_specs(...)` so it works in either mode.

## The Meta-Pattern

The best compression preserves the most degrees of freedom per weight group while keeping enough data per group for the algorithm to work well. This explains why per-channel palettization with boundary-layer skipping consistently wins — maximum adaptation per channel, and the hardest layers are left uncompressed.

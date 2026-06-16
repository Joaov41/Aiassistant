---
name: model-authoring
description: Empirical rules for authoring PyTorch models for on-device execution on Apple platforms, covering energy-efficient inference, scalable compute, and correctness testing. Use this skill whenever the user is writing, debugging, or reviewing PyTorch model code intended for on-device execution — even if they don't explicitly mention Neural Engine or Core AI. Covers BC1S layout, op compatibility, KV cache patterns, precision rules, PSNR verification, activation functions, and common issues.
---

# Model Authoring

This skill contains the hard-won empirical knowledge for making PyTorch models compile and run correctly on Apple hardware via Core AI. The rules here are stable across Core AI releases — they reflect hardware behavior, not API shapes.

## Reference material

Use these resources on-demand — **do not read all files upfront**. Consult the relevant reference when the user's task requires specific patterns for a target platform, or when debugging.

| Resource | When to consult |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`neural_engine_rules.md`](references/neural_engine_rules.md) | Neural Engine patterns: BC1S layout, Conv2d projections, per-head attention, KV cache readonly pattern, stride/dilation/pooling rules, causal mask, RoPE, chunked prefill |
| [`gpu_rules.md`](references/gpu_rules.md) | GPU patterns: fused QKV, native SDPA, KV cache stateful pattern, MoE (GatherMM/SwitchLinear), memory-efficient loading, RMSNorm variants |
| [`common_issues.md`](references/common_issues.md) | Debugging: PSNR issues, compilation errors, runtime problems, stale flags |
| [coreai-models repo](https://github.com/apple/coreai-models) | Complete working reference implementations for LLMs, vision, audio, diffusion. Explore `primitives/` and `models/` directories. |

### coreai-models: working reference implementations

For complex models (LLMs, MoE, multimodal, diffusion), **explore the coreai-models repo before writing primitives from scratch**. It has complete authoring primitives for both GPU and Neural Engine, including advanced patterns like iOS embedding quantization, MoE routing, and memory-efficient weight loading for large models. If the user has a local clone, explore it directly. If not, suggest cloning it.

**Online docs**: [coreai-torch composite ops](https://apple.github.io/coreai-torch/guides/composite-ops.html) | [externalization](https://apple.github.io/coreai-torch/guides/externalization.html) | [composite ops API](https://apple.github.io/coreai-torch/api/composite-ops.html)

______________________________________________________________________

## Model optimization — use working-with-coreai

Model optimization decisions (precision, compression, device compatibility) are resolved by the `working-with-coreai` skill.

- If the active plan contains deployment decisions (platform, compression approach), follow those. The plan uses "optimize for energy efficiency" (BC1S, Conv2d, static shapes, fp16) and "optimize for scalable performance" (standard layout, nn.Linear, dynamic shapes supported).
- If no deployment context exists and the user's intent is ambiguous, invoke `Skill("coreai-skills:working-with-coreai")` before authoring.

| User talks about… | Likely compute unit | Why |
| -------------------------------------------------------------- | ----------------- | ----------------------------------------------- |
| Energy efficiency, battery life, iOS, iPhone, iPad, always-on | **Neural Engine** | Most energy-efficient compute unit |
| Max performance, throughput, macOS, large batches, flexibility | **GPU** | GPU excels at throughput and flexible workloads |
| Correctness testing, debugging, reference implementation | **CPU** | CPU runs everything, good for validation |

**If the user explicitly names an accelerator** (Neural Engine, GPU, CPU), use their choice. Otherwise, infer from context and use outcome-oriented language in your responses — say "optimized for energy-efficient inference on iPhone" rather than "targets Neural Engine". Mirror the user's vocabulary: if they say Neural Engine, match them.

______________________________________________________________________

## Compute unit characteristics

| Compute unit | Strengths | Key authoring constraint |
| ----------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| **Neural Engine** | Energy-efficient, battery-friendly, static workloads | BC1S layout, fp16 only, static shapes, limited op set |
| **GPU** | High throughput, large models, flexible ops | Standard PyTorch layout, supports fp32 |
| **CPU** | Small models, low overhead, low latency, correctness testing, fallback | Runs all ops, good for validation |

______________________________________________________________________

## Neural Engine and GPU at a glance

Quick reference for the key authoring differences. Consult `neural_engine_rules.md` or `gpu_rules.md` for full details.

| Aspect | Neural Engine | GPU |
| ----------------- | ------------------------------------------ | ----------------------------------- |
| Tensor layout | BC1S `(B, H*D, 1, S)` | Standard `(B, S, D)` |
| Projections | `nn.Conv2d(kernel_size=1)` | `nn.Linear` (fused QKV on GPU) |
| Embedding shape | `(V, 1, D)` — externalized | Standard `nn.Embedding` |
| Attention | Per-head sequential | Fused native SDPA |
| Float precision | fp16 only — no fp32 literals anywhere | fp16 weights, fp32 intermediates OK |
| Shapes | Fully static | Dynamic shapes supported |
| Weight conversion | `unsqueeze(-1).unsqueeze(-1)` for Conv2d | No reshape needed |

______________________________________________________________________

## Authoring workflow

### Phase 1: Architecture discovery

Run code, don't read code. Running gives ground truth instantly.

1. Print model structure and state dict keys with shapes
2. Trace forward pass with `register_forward_hook` — capture intermediates
3. Document target hardware, IO boundary, module hierarchy, activation type, KV cache layout

### Phase 2: Primitive implementation (bottom-up)

Author in this order — each depends on the previous:

1. **Norm** — layout and weight shape depend on target
2. **Linear projections** — Conv2d(in, out, 1) for Neural Engine; nn.Linear for GPU
3. **Attention** — layout, K@Q convention, causal mask depend on target
4. **MLP / FFN** — activation must match source exactly
5. **Full decoder block** — compose primitives with KV cache wiring

### Verification gates

| Comparison | Threshold | Meaning |
| ------------------------------------------ | --------- | -------------------------------------------- |
| Re-authored vs source (torch) | > 70 dB | Implementation correct |
| Neural Engine layout vs GPU layout (torch) | > 70 dB | Layout transformation correct |
| Compiled vs torch | >= 40 dB | Compilation precision (fp16 + optimizations) |
| After 4-bit palettization | >= 35 dB | Compression acceptable |

Verify each primitive individually before composing the full model. Also compare the full re-authored model's outputs against a baseline export (direct from HuggingFace without re-authoring) — both in Python and after compilation on device — to confirm end-to-end parity.

### The `from_source_model` classmethod

Every re-authored model gets a factory classmethod — no hardcoded constants:

```python
@classmethod
def from_source_model(cls, source_model) -> "MyDecoder":
    cfg = source_model.config
    model = cls(
        n_layers=cfg.num_hidden_layers,
        hidden=cfg.hidden_size,
        n_heads=cfg.num_attention_heads,
        # ...
    )
    model.load_weights_from(source_model.state_dict())
    return model
```

______________________________________________________________________

## KV cache conventions

Both Neural Engine and GPU require explicit KV cache management, but the patterns differ:

| Compute unit | Cache shape | Sequence dim | Pattern | Details |
| ----------------- | --------------------------------- | ------------ | -------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **Neural Engine** | `[n_layers, B, H_kv*D, 1, max_S]` | dim 4 | Readonly functional I/O — model has no cache writes, returns new K/V tokens as outputs | [`neural_engine_rules.md`](references/neural_engine_rules.md) |
| **GPU** | `[n_layers, B, H_kv, max_S, D]` | dim 3 | Stateful export wrapper — `register_buffer` for KV, `hoistToArg` at compile | [`gpu_rules.md`](references/gpu_rules.md) |

**Key rule**: Do not use stateful transforms for token generation — state resets between inference calls. Use the readonly KV I/O pattern (Neural Engine) or the stateful export wrapper (GPU) instead.

______________________________________________________________________

## Palettization (weight compression)

Apply **after** authoring float16 model passes verification, **before** Core AI export.

For compression exploration and configuration, use `Skill("coreai-skills:model-compression-exploration")` which covers `coreai-opt` quantization and palettization sweeps.

Key facts for authoring:

- 4-bit palettization: ~4x size reduction, PSNR ~40 dB vs float16
- Palettize Conv2d / Linear only — skip embeddings, norms, bias
- State dict keys gain `._data`, `._lut`, `._indices` suffixes after compression
- Size reduction is realized in the compiled `.aimodel`, not in the PyTorch checkpoint

| Bits | Size reduction | Typical PSNR | Flag if below |
| ----- | -------------- | ------------ | -------------------- |
| 8-bit | ~2x | > 55 dB | 50 dB |
| 4-bit | ~4x | ~40 dB | 35 dB |
| 2-bit | ~8x | ~25-35 dB | Usually unacceptable |

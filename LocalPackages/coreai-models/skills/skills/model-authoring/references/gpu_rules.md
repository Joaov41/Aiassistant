# GPU / CPU Rules

The same authoring principles apply to both GPU and CPU. GPU uses standard PyTorch tensor layouts; CPU is used for correctness testing before compilation.

## General Authoring Rules

These patterns apply to any model running on GPU or CPU, regardless of architecture.

### Layout

Standard PyTorch shapes throughout — no BC1S conversion needed.

| Tensor | Shape |
| ------------- | ----------------------- |
| Hidden states | `(B, S, D)` or `(B, D)` |
| Multi-head | `(B, H, S, D)` |

Use `nn.Linear` for all projections. No weight reshape needed.

______________________________________________________________________

### Activation functions

Always verify the source activation type before re-authoring:

```python
for name, mod in source_model.named_modules():
    if hasattr(mod, "act") or "activation" in name.lower():
        print(name, type(mod))
```

Common types: `nn.SiLU`, `nn.GELU`, `QuickGELU`, `SwiGLU`. They are **not interchangeable** — wrong activation gives PSNR ~20-30 dB.

GPU supports all standard PyTorch activation functions natively.

______________________________________________________________________

### Float16

Use float16 weights for models that may run on GPU/CPU on-device:

```python
model = model.half().eval()
inputs = {k: v.astype(np.float16) for k, v in inputs.items()}
```

Use fp32 intermediates selectively for numerical stability in sensitive operations (normalization, attention scores).

______________________________________________________________________

### Native SDPA

GPU uses fused scaled dot-product attention — a single call processes all heads in parallel:

```python
attn_output = F.scaled_dot_product_attention(
    query,
    key,
    value,
    attn_mask=mask,
    is_causal=is_causal,
)
```

This is the opposite of Neural Engine, where each head must be computed individually. On GPU, fused SDPA is both simpler to author and faster to execute.

______________________________________________________________________

### RMSNorm variants

GPU supports standard RMSNorm and also richer variants that may not map cleanly to Neural Engine:

- **RMSNormPlusOne**: `weight + 1.0` offset (used by Gemma3, some Qwen variants)
- **RMSNormGated**: Applies SiLU gating after normalization

On GPU, implement these directly as the source model defines them.

______________________________________________________________________

### Compilation

For GPU, use `mutable_arg_action="hoistToArg"` in `LegalizeToCoreOptions`. This converts mutable weights to function arguments with defaults, appropriate for GPU/CPU.

______________________________________________________________________

### Code style

#### Factory classmethod

```python
@classmethod
def from_source_model(cls, source_model) -> "GPUDecoder":
    cfg = source_model.config
    model = cls(
        n_layers=cfg.num_hidden_layers,
        hidden=cfg.hidden_size,
        n_heads=cfg.num_attention_heads,
        n_kv_heads=cfg.num_key_value_heads,
        head_dim=getattr(cfg, "head_dim", cfg.hidden_size // cfg.num_attention_heads),
        intermediate=cfg.intermediate_size,
        max_seq_len=cfg.max_position_embeddings,
        vocab_size=cfg.vocab_size,
    )
    model.load_weights_from(source_model.state_dict())
    return model
```

#### Directory layout

```plaintext
model_dir/
├── primitives.py      ← RMSNorm, RoPE, Attention, MLP
├── decoder_layer.py   ← DecoderLayer = primitives + KV cache wiring
└── full_model.py      ← embed + all layers + lm_head
```

#### State dict keys

Print source keys before writing any remap — do not guess:

```python
sd = source_model.state_dict()
for k in sorted(sd.keys()):
    print(k, sd[k].shape)
```

______________________________________________________________________

## LLM / Transformer-Specific Patterns

These patterns apply specifically to transformer-based models (LLMs, ASR, etc.).

### Fused QKV projection

Combine separate Q, K, V projections into a single `nn.Linear` for reduced memory bandwidth:

```python
self.qkv_proj = nn.Linear(
    dim,
    n_heads * head_dim + 2 * n_kv_heads * head_dim,  # Q + K + V
    bias=False,
)
```

State dict mutation concatenates the three weight tensors:

```python
q_weight = state_dict[f"layers.{i}.self_attn.q_proj.weight"]
k_weight = state_dict[f"layers.{i}.self_attn.k_proj.weight"]
v_weight = state_dict[f"layers.{i}.self_attn.v_proj.weight"]
state_dict[f"layers.{i}.self_attn.qkv_proj.weight"] = torch.cat(
    [q_weight, k_weight, v_weight], dim=0
)
```

______________________________________________________________________

### Fused Q/K normalization + RoPE

After the fused QKV projection, apply normalization and RoPE to the combined Q+K slice before splitting — this reduces kernel launches:

```python
qkv = self.qkv_proj(x)
query_key = qkv.narrow(-1, 0, (n_heads + n_kv_heads) * head_dim)
query_key = self.qk_norm(query_key)
query_key = self.rope(query_key, position_ids=position_ids)
query = query_key.narrow(-1, 0, n_heads * head_dim)
key = query_key.narrow(-1, n_heads * head_dim, n_kv_heads * head_dim)
value = qkv.narrow(-1, (n_heads + n_kv_heads) * head_dim, n_kv_heads * head_dim)
```

______________________________________________________________________

### MLP operation ordering

Compute `up_proj` before `gate_proj` for better GPU throughput:

```python
def forward(self, x: torch.Tensor) -> torch.Tensor:
    up_tensor = self.up_proj(x)  # up first
    gate_tensor = F.silu(self.gate_proj(x))  # gate second
    return self.down_proj(up_tensor * gate_tensor)
```

This ordering is reversed from many reference implementations but yields better GPU utilization.

______________________________________________________________________

### KV cache

Shape `[n_layers, B, H_kv, max_S, D]`, sequence on **dim 3**. Module buffer.

For `torch.export`, wrap in a model class that registers KV cache buffers as explicit module inputs/outputs so they appear in the exported graph signature.

**Cache mutation via `mutable_slice_update`**: The macOS KV cache uses a custom op (`coreai::mutable_slice_update`) to thread in-place mutation through `torch.export`. Its eager implementation mutates the cache tensor in-place; its meta/fake implementation returns a new tensor of the same shape, making it compatible with export's functional semantics. This is the mechanism behind stateful KV cache export — explore coreai-models `primitives/macos/cache.py` for the full pattern.

______________________________________________________________________

### Causal mask

Standard upper-triangular mask, shape `(1, 1, S, S)` or `(B, 1, S, S)`:

```python
mask = torch.triu(torch.ones(seq_len, seq_len), diagonal=1).bool()
mask = mask.masked_fill(mask, float("-inf"))  # GPU handles -inf correctly
```

______________________________________________________________________

### Positional embeddings

Precompute everything that does not depend on input values as a model buffer:

```python
# BAD — recomputes trig per token
rotary = MRoPEEmbedding(config).eval()
gpu_cos, gpu_sin = rotary(embed_t.float(), pos_ids)

# GOOD — single buffer slice, no compute
cos, sin = model.get_cos_sin(pos, seq_len=1, dtype=torch.float16)
```

Register as `register_buffer("cos_table", ..., persistent=True)` in `__init__`. Slice at runtime.

______________________________________________________________________

### Stateful KV cache export wrapper

Wrap your model to register KV cache buffers as module state (required for `torch.export` to see them as explicit I/O):

```python
class ExportableDecoderModel(nn.Module):
    def __init__(self, decoder, n_layers, n_kv_heads, max_seq_len, head_dim):
        super().__init__()
        self.decoder = decoder
        self.register_buffer(
            "_full_cached_k",
            torch.zeros(
                n_layers, 1, n_kv_heads, max_seq_len, head_dim, dtype=torch.float16
            ),
            persistent=False,
        )
        self.register_buffer(
            "_full_cached_v",
            torch.zeros(
                n_layers, 1, n_kv_heads, max_seq_len, head_dim, dtype=torch.float16
            ),
            persistent=False,
        )

    def forward(self, inputs_embeds, position_ids):
        return self.decoder(
            inputs_embeds, position_ids, self._full_cached_k, self._full_cached_v
        )
```

Use `mutable_arg_action="hoistToArg"` in `LegalizeToCoreOptions` for GPU.

> **Stateful transforms warning**: Stateful transform APIs reset state between inference calls. Do not use for token generation. Use the readonly KV I/O pattern instead (see `neural_engine_rules.md`).

______________________________________________________________________

### Mixture of Experts (MoE)

For models with sparse expert routing (e.g., Qwen3-MoE, Mixtral), use the `GatherMM` composite op via `SwitchLinear`:

**Pattern:**

- **`SwitchLinear`**: A single weight tensor of shape `(num_weight_sets, num_experts, output_dims, input_dims)` holding all experts. At inference time, takes indices of selected experts and performs batched gather + matmul in one operation via `coreai_torch.composite_ops.GatherMM`.
- **`SwitchGLU`**: Combines three `SwitchLinear` layers (gate, up, down) with SwiGLU activation for MoE MLP blocks.
- **Routing**: Standard `nn.Linear` gate + softmax + top-k selection to choose active experts per token. Expert indices are typically cast to `uint16` before passing to GatherMM.

**State dict mutation for MoE**: HuggingFace stores per-expert weights separately (e.g., `experts.0.gate_proj.weight`, `experts.1.gate_proj.weight`). At load time, stack them into the `(1, num_experts, out, in)` shape expected by `SwitchLinear`.

Explore coreai-models for complete MoE model implementations (e.g., Qwen3-MoE, Mixtral).

______________________________________________________________________

### Memory-efficient weight loading

For large models (7B+), avoid holding both the source HuggingFace model and the re-authored model in RAM simultaneously:

**Meta-device initialization**: Allocate the model structure without any memory:

```python
model = MyReauthoredModel(config, device="meta")
```

**Assign-mode loading**: Load weights directly into the model without copying:

```python
model.load_state_dict(mutated_state_dict, assign=True)
```

**Streaming one layer at a time**: For very large models, open safetensors files directly, process one layer's weights (mutate state dict keys, reshape for Conv2d or fuse QKV), load that layer, then move to the next. Peak RAM is roughly one layer rather than the full model.

Explore coreai-models for the `from_hf_memory_efficient` pattern that implements this end-to-end.

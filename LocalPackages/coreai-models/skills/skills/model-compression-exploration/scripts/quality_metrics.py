"""Output-quality metrics for compression experiments.

Pure tensor math — no coreai-opt dependency. Each metric compares the
compressed model's output against the fp16 baseline output.

- ``psnr`` and ``snr`` are appropriate for continuous outputs (logits,
  feature maps).
- ``iou`` is appropriate for binary or thresholded outputs (segmentation
  masks, detection heatmaps).

``compute_quality_metrics`` is the sweep-side dispatcher: given the
model's outputs, the baseline outputs, and a per-output metric name,
it returns the report-shaped list of dicts.
"""

from __future__ import annotations

import torch


_EPS_SIGNAL = 1e-10
_EPS_NOISE = 1e-7


def psnr(data: torch.Tensor, ref: torch.Tensor) -> float:
    """Peak signal-to-noise ratio in dB.

    Uses the maximum squared signal magnitude (not the dynamic range)
    as the peak — matches the convention used elsewhere in this repo.
    """
    data = data.float().flatten()
    ref = ref.float().flatten()
    noise_var = torch.sum((data - ref) ** 2) / data.numel()
    max_signal = torch.amax(ref**2)
    return float(
        10 * torch.log10((max_signal + _EPS_SIGNAL) / (noise_var + _EPS_NOISE))
    )


def snr(data: torch.Tensor, ref: torch.Tensor) -> float:
    """Signal-to-noise ratio in dB."""
    data = data.float().flatten()
    ref = ref.float().flatten()
    noise_var = torch.sum((data - ref) ** 2) / data.numel()
    sig = torch.sum(ref**2) / ref.numel()
    return float(10 * torch.log10((sig + _EPS_SIGNAL) / (noise_var + _EPS_NOISE)))


def iou(pred: torch.Tensor, ref: torch.Tensor, threshold: float = 0.5) -> float:
    """Intersection-over-union for thresholded tensors.

    Both inputs are thresholded at ``threshold`` and compared as boolean
    masks. Returns 1.0 when both masks are empty (no positive pixels).
    """
    p = (pred > threshold).bool()
    r = (ref > threshold).bool()
    inter = (p & r).sum().item()
    union = (p | r).sum().item()
    return float(inter / union) if union else 1.0


_REGISTRY = {"psnr": psnr, "snr": snr, "iou": iou}


def compute(metric: str, data: torch.Tensor, ref: torch.Tensor) -> float:
    """Dispatch to the named metric. Raises ValueError on unknown names."""
    if metric not in _REGISTRY:
        raise ValueError(f"Unknown metric {metric!r}; choose from {sorted(_REGISTRY)}")
    return _REGISTRY[metric](data, ref)


def compute_quality_metrics(
    outputs,
    references,
    metric_per_output: list[str],
) -> list[dict]:
    """Compute per-output metrics and return the report-shaped list.

    ``outputs`` / ``references`` may each be a single tensor, a tuple/list
    of tensors, or a dict keyed by output name. They must share shape.
    ``metric_per_output`` lists one metric name per flattened output, in
    the same order.

    Returns:
        ``[{"name": str, "metric": str, "value": float}, ...]``
    """
    out_list, ref_list, names = _flatten(outputs, references)
    if len(metric_per_output) != len(out_list):
        raise ValueError(
            f"metric_per_output has {len(metric_per_output)} entries but "
            f"got {len(out_list)} outputs"
        )
    return [
        {"name": n, "metric": m, "value": compute(m, o, r)}
        for n, m, o, r in zip(names, metric_per_output, out_list, ref_list)
    ]


def _flatten(outputs, references) -> tuple[list, list, list[str]]:
    if isinstance(outputs, torch.Tensor):
        return [outputs], [references], ["out_0"]
    if isinstance(outputs, dict):
        names = list(outputs.keys())
        return [outputs[k] for k in names], [references[k] for k in names], names
    out_list = list(outputs)
    ref_list = list(references)
    return out_list, ref_list, [f"out_{i}" for i in range(len(out_list))]

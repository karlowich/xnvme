#!/usr/bin/env python
"""
    xNVMe performance regression: baseline-vs-candidate verdict
    ===========================================================

    Compares two ``xnvmeperf_bench`` result sets -- the ``baseline`` and
    ``candidate`` label subdirs under the run's own ``<output>/xnvmeperf/`` --
    and, per operating point and metric, computes mean, sd and a 95% confidence
    interval (Student's t) across reps. A metric is a REGRESSION only when the
    candidate is worse by more than ``--tolerance`` (relative) *and* the two
    confidence intervals are disjoint, so neither noise nor a sub-tolerance
    shift trips the verdict.

    Because both sets come from the same invocation's ``<output>``, baseline and
    candidate are always measured in the same run -- results cannot be reused
    across runs, so a stale build never silently confounds the comparison.

    Metrics: iops, mibs, efficiency (iops/%CPU) -- higher is better; cpu (%CPU)
    -- lower is better. Any metric regressing regresses its point; any point
    regressing fails the run (non-zero exit) to gate CI.

    Retargetable: False
"""
import json
import logging as log
from argparse import ArgumentParser
from math import sqrt
from pathlib import Path

# Student's t, two-sided 95%, by degrees of freedom (n-1). Index by df, capped.
T95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
    8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
    15: 2.131, 20: 2.086, 25: 2.060, 30: 2.042, 40: 2.021, 60: 2.000,
}

# (name, higher_is_better)
METRICS = [
    ("iops", True),
    ("mibs", True),
    ("efficiency", True),
    ("cpu", False),
]


def add_args(parser: ArgumentParser):
    parser.add_argument("--baseline-label", type=str, help="Baseline label/subdir (default baseline)")
    parser.add_argument("--candidate-label", type=str, help="Candidate label/subdir (default candidate)")
    parser.add_argument(
        "--tolerance",
        type=float,
        help="Relative degradation that must be exceeded to flag (default 0.01)",
    )


def cfg(args, cijoe, arg_name, conf_key, default=None):
    """Option value if set, else config [regression].<conf_key>, else default."""

    val = getattr(args, arg_name, None)
    if val is not None:
        return val
    val = cijoe.getconf(f"regression.{conf_key}", None)
    return val if val is not None else default


def t95(df: int) -> float:
    if df <= 0:
        return float("inf")
    if df in T95:
        return T95[df]
    # Largest tabulated df below the request: smaller df -> larger t (wider
    # interval), the conservative choice. Falls back to normal approx (1.96).
    below = [k for k in T95 if k < df]
    return T95[max(below)] if below else 1.96


def load(results_dir: Path) -> dict:
    """key -> {metric -> [values]} plus label, grouped over reps."""

    grouped: dict = {}
    for path in sorted(Path(results_dir).glob("*.json")):
        with open(path) as f:
            r = json.load(f)
        g = grouped.setdefault(r["key"], {"label": r.get("label", ""), "vals": {}})
        for name, _ in METRICS:
            v = r.get(name)
            if v is not None:
                g["vals"].setdefault(name, []).append(float(v))
    return grouped


def stats(values: list):
    """Return (mean, sd, margin) for a sample.

    margin is the 95% confidence-interval half-width (margin of error).
    """

    n = len(values)
    mean = sum(values) / n
    if n < 2:
        return mean, 0.0, 0.0
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    sd = sqrt(var)
    margin = t95(n - 1) * sd / sqrt(n)
    return mean, sd, margin


def judge(base, cand, higher_better: bool, tol: float):
    """Return (verdict, rel_change) for one metric.

    rel_change is signed candidate-vs-baseline change in the 'good' direction
    (negative == worse). verdict in {"ok", "regression", "improved"}.
    """

    b_mean, _, b_margin = base
    c_mean, _, c_margin = cand
    if b_mean == 0:
        return "ok", 0.0

    delta = c_mean - b_mean
    # Express change so that negative is always "worse".
    good_delta = delta if higher_better else -delta
    rel = good_delta / abs(b_mean)

    # Disjoint 95% confidence intervals == statistically significant difference.
    significant = abs(delta) > (b_margin + c_margin)

    if abs(rel) > tol and significant:
        return ("regression" if good_delta < 0 else "improved"), rel
    return "ok", rel


def main(args, cijoe):
    tolerance = cfg(args, cijoe, "tolerance", "tolerance", 0.01)
    base_name = args.baseline_label or "baseline"
    cand_name = args.candidate_label or "candidate"

    root = Path(args.output) / "xnvmeperf"
    base_dir = root / base_name
    cand_dir = root / cand_name
    if not base_dir.is_dir() or not cand_dir.is_dir():
        log.error(f"Failed: expected result dirs {base_dir} and {cand_dir}")
        return 1

    base = load(base_dir)
    cand = load(cand_dir)

    keys = sorted(set(base) & set(cand))
    if not keys:
        log.error("Failed: no overlapping points between baseline and candidate")
        return 1

    missing = (set(base) | set(cand)) - set(keys)
    for k in sorted(missing):
        log.warning(f"point present in only one set, skipped: {k}")

    base_label = next(iter(base.values()))["label"] or base_name
    cand_label = next(iter(cand.values()))["label"] or cand_name

    lines = []
    lines.append(f"# xnvmeperf regression: {cand_label} vs {base_label}")
    lines.append("")
    lines.append(f"tolerance: {tolerance:.1%}; margin = 95% confidence interval "
                 f"half-width (Student's t)")
    lines.append("")
    header = (
        "| point | metric | "
        f"{base_label} (mean±margin) | {cand_label} (mean±margin) | Δ% | verdict |"
    )
    lines.append(header)
    lines.append("|---|---|---|---|---|---|")

    regressions = []
    for key in keys:
        bvals = base[key]["vals"]
        cvals = cand[key]["vals"]
        first = True
        for name, higher in METRICS:
            if name not in bvals or name not in cvals:
                continue
            b = stats(bvals[name])
            c = stats(cvals[name])
            verdict, rel = judge(b, c, higher, tolerance)
            if verdict == "regression":
                regressions.append((key, name, rel))
            tag = {"ok": "ok", "regression": "**REGRESSION**",
                   "improved": "improved"}[verdict]
            point_cell = key if first else ""
            first = False
            lines.append(
                f"| {point_cell} | {name} | "
                f"{b[0]:.0f}±{b[2]:.0f} | {c[0]:.0f}±{c[2]:.0f} | "
                f"{rel*100:+.2f} | {tag} |"
            )

    lines.append("")
    if regressions:
        lines.append(f"**RESULT: REGRESSION** ({len(regressions)} metric(s))")
        for key, name, rel in regressions:
            lines.append(f"- {key}: {name} {rel*100:+.2f}%")
    else:
        lines.append(
            "**RESULT: PASS** (no regressions beyond tolerance + 95% "
            "confidence interval)"
        )

    report = "\n".join(lines)
    print(report)

    artifacts = Path(args.output) / "artifacts"
    cijoe.run_local(f"mkdir -p {artifacts}")
    with open(artifacts / "xnvmeperf-regression.md", "w") as f:
        f.write(report + "\n")

    return 1 if regressions else 0

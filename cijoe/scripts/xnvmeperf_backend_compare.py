#!/usr/bin/env python
"""
    xNVMe performance: backend-vs-backend comparison
    ================================================

    Companion to ``xnvmeperf_regression`` for comparing two *backends* measured
    in the *same* build, rather than two builds of one backend. ``xnvmeperf_bench``
    sweeps ``backends x iosizes x ... x cpumasks`` and keys each point by
    backend, so the regression comparator (which pairs identical keys) never
    pairs ``dmamem`` against ``upcie``. This reads one label subdir, groups by
    operating point *ignoring* the backend, and pairs a ``candidate_backend``
    (default dmamem) against a ``baseline_backend`` (default upcie).

    Per point and metric it reports both backends' mean and 95% confidence
    interval (Student's t) across reps, the candidate-vs-baseline relative
    change, and whether the two intervals are disjoint (statistically
    significant). Metrics, stats and the significance rule are reused verbatim
    from ``xnvmeperf_regression`` -- see it for the definitions.

    This is a characterization, not a CI gate: it emits a markdown table to
    ``<output>/artifacts/dmamem-vs-upcie.md`` and always returns 0.

    Retargetable: False
"""
import json
import logging as log
import sys
from argparse import ArgumentParser
from pathlib import Path

# Reuse the stats/verdict machinery from the sibling regression comparator.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import xnvmeperf_regression as reg  # noqa: E402


def add_args(parser: ArgumentParser):
    parser.add_argument("--label", type=str, help="Result subdir to read (e.g. iommu_off)")
    parser.add_argument("--baseline-backend", type=str, help="Reference backend (default upcie)")
    parser.add_argument("--candidate-backend", type=str, help="Backend under test (default dmamem)")
    parser.add_argument(
        "--tolerance",
        type=float,
        help="Relative difference that must be exceeded to flag (default 0.01)",
    )


def cfg(args, cijoe, arg_name, conf_key, default=None):
    """Option value if set, else config [regression].<conf_key>, else default."""

    val = getattr(args, arg_name, None)
    if val is not None:
        return val
    val = cijoe.getconf(f"regression.{conf_key}", None)
    return val if val is not None else default


def popcount_hex(mask: str) -> int:
    """Number of set bits (== pinned threads) in a hex --cpumask string."""

    try:
        return bin(int(mask, 16)).count("1")
    except ValueError:
        return 0


def point_label(rec: dict) -> str:
    """Stable operating-point id independent of backend/rep."""

    return (
        f"o{rec['iosize']}-q{rec['qdepth']}-d{rec['ndevs']}"
        f"-m{rec['cpumask']}-{rec['iopattern']}"
    )


def load(results_dir: Path) -> dict:
    """point -> {backend -> {metric -> [values]}} plus the point's fields."""

    points: dict = {}
    for path in sorted(Path(results_dir).glob("*.json")):
        with open(path) as f:
            r = json.load(f)
        p = points.setdefault(
            point_label(r),
            {
                "iosize": r["iosize"], "qdepth": r["qdepth"], "ndevs": r["ndevs"],
                "cpumask": r["cpumask"], "iopattern": r["iopattern"], "backends": {},
            },
        )
        be = p["backends"].setdefault(r["backend"], {})
        for name, _ in reg.METRICS:
            v = r.get(name)
            if v is not None:
                be.setdefault(name, []).append(float(v))
    return points


def main(args, cijoe):
    label = cfg(args, cijoe, "label", "label")
    base_be = cfg(args, cijoe, "baseline_backend", "baseline_backend", "upcie")
    cand_be = cfg(args, cijoe, "candidate_backend", "candidate_backend", "dmamem")
    tolerance = cfg(args, cijoe, "tolerance", "tolerance", 0.01)
    if not label:
        log.error("Failed: no 'label' given (option or [regression].label)")
        return 1

    results_dir = Path(args.output) / "xnvmeperf" / label
    if not results_dir.is_dir():
        log.error(f"Failed: expected result dir {results_dir}")
        return 1

    points = load(results_dir)
    if not points:
        log.error(f"Failed: no results under {results_dir}")
        return 1

    # Order points by thread count then cpumask, iosize -- a readable progression.
    ordered = sorted(
        points.items(),
        key=lambda kv: (popcount_hex(kv[1]["cpumask"]), kv[1]["cpumask"], kv[1]["iosize"]),
    )

    lines = []
    lines.append(f"# xnvmeperf backend comparison: {cand_be} vs {base_be} ({label})")
    lines.append("")
    lines.append(
        f"tolerance: {tolerance:.1%}; margin = 95% confidence-interval half-width "
        f"(Student's t); Δ% = {cand_be} vs {base_be} in the 'good' direction "
        f"(negative == {cand_be} worse); (*) = 95% intervals disjoint."
    )
    lines.append("")
    lines.append(
        f"| point | threads | metric | {base_be} (mean±margin) | "
        f"{cand_be} (mean±margin) | Δ% | |"
    )
    lines.append("|---|---|---|---|---|---|---|")

    flagged = []
    for pid, p in ordered:
        bevals = p["backends"]
        threads = popcount_hex(p["cpumask"])
        if base_be not in bevals or cand_be not in bevals:
            log.warning(f"{pid}: missing {base_be} or {cand_be}, skipped")
            continue
        first = True
        for name, higher in reg.METRICS:
            b_vals = bevals[base_be].get(name)
            c_vals = bevals[cand_be].get(name)
            if not b_vals or not c_vals:
                continue
            b = reg.stats(b_vals)
            c = reg.stats(c_vals)
            verdict, rel = reg.judge(b, c, higher, tolerance)
            sig = "*" if verdict in ("regression", "improved") else ""
            if sig:
                flagged.append((pid, name, rel, verdict))
            point_cell = pid if first else ""
            thr_cell = str(threads) if first else ""
            first = False
            lines.append(
                f"| {point_cell} | {thr_cell} | {name} | "
                f"{b[0]:.0f}±{b[2]:.0f} | {c[0]:.0f}±{c[2]:.0f} | "
                f"{rel*100:+.2f} | {sig} |"
            )

    lines.append("")
    if flagged:
        lines.append(f"**Significant differences ({len(flagged)}):**")
        for pid, name, rel, verdict in flagged:
            better = "faster/leaner" if verdict == "improved" else "slower/heavier"
            lines.append(f"- {pid}: {name} {rel*100:+.2f}% ({cand_be} {better})")
    else:
        lines.append(
            "**No differences beyond tolerance + 95% confidence interval.**"
        )

    report = "\n".join(lines)
    print(report)

    artifacts = Path(args.output) / "artifacts"
    cijoe.run_local(f"mkdir -p {artifacts}")
    with open(artifacts / "dmamem-vs-upcie.md", "w") as f:
        f.write(report + "\n")

    return 0

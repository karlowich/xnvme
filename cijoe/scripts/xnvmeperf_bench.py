#!/usr/bin/env python
"""
    xNVMe performance regression: measurement runner
    ================================================

    Sweeps the cross-product of ``backends x iosizes x qdepths x ndevs x
    cpumasks`` over ``xnvmeperf``, writing one JSON result per repetition under
    cijoe's per-run output directory: ``<output>/xnvmeperf/<label>`` (``ndevs``
    selects the first N of the config's ``[[devices]]``). Each axis, plus
    ``runtime``/``repetitions``/``iopattern``/``label``, comes from an option or
    the ``[regression]`` config section (option wins), keeping the workflow
    value-free.

    Results live in the run's ``<output>`` (cijoe moves the previous one to
    ``cijoe-archive`` at the start of every invocation), so each run is
    self-contained and results are never silently reused across runs -- run the
    baseline and candidate as steps of one invocation, distinguished by
    ``label``, then compare with ``xnvmeperf_regression``.

    Runs are wrapped in GNU ``/usr/bin/time`` to record %CPU alongside IOPS and
    MiB/s, so the comparator can judge efficiency (IOPS per %CPU) even when
    throughput is pinned by a hardware ceiling.

    Retargetable: True
"""
import json
import logging as log
import re
from argparse import ArgumentParser
from itertools import product
from pathlib import Path

# Matches the 'Total:' row of xnvmeperf's table: name, cpus, iops, mibs, fails
PERF_RE = re.compile(
    r"\s*(?P<name>\w+):?\s+(?P<cpus>[0-9,]+)?\s+"
    r"(?P<iops>[0-9.]+)\s+(?P<mibs>[0-9.]+)\s+(?P<fails>[0-9.]+)"
)
# Matches the %CPU field emitted by GNU /usr/bin/time
TIME_RE = re.compile(r"(?P<cpu>[0-9.]+)%CPU")


def add_args(parser: ArgumentParser):
    parser.add_argument("--backends", type=str, nargs="+", help="xNVMe backends")
    parser.add_argument("--iosizes", type=int, nargs="+", help="I/O sizes (bytes)")
    parser.add_argument("--qdepths", type=int, nargs="+", help="Queue depths")
    parser.add_argument("--ndevs", type=int, nargs="+", help="Device counts")
    parser.add_argument("--cpumasks", type=str, nargs="+", help="Hex CPU masks")
    parser.add_argument("--iopattern", type=str, help="read/write/randread/randwrite")
    parser.add_argument("--runtime", type=int, help="Seconds per run")
    parser.add_argument("--repetitions", type=int, help="Repetitions per point")
    parser.add_argument("--label", type=str, help="Build label; names the result subdir")


def cfg(args, cijoe, name, default=None):
    """Option value if set, else config [regression].<name>, else default."""

    val = getattr(args, name, None)
    if val is not None:
        return val
    val = cijoe.getconf(f"regression.{name}", None)
    return val if val is not None else default


def point_key(be, iosize, qdepth, ndevs, cpumask, pattern) -> str:
    """Stable identifier for a point, independent of build/rep."""

    return f"be_{be}-o{iosize}-q{qdepth}-d{ndevs}-m{cpumask}-{pattern}"


def parse_output(output: str):
    """Return (iops, mibs, fails, cpu) parsed from xnvmeperf+time output."""

    iops = mibs = fails = cpu = None
    for line in output.splitlines():
        m = PERF_RE.match(line)
        if m and m.group("name") == "Total":
            iops = float(m.group("iops"))
            mibs = float(m.group("mibs"))
            fails = float(m.group("fails"))
        t = TIME_RE.search(line)
        if t:
            cpu = float(t.group("cpu"))
    return iops, mibs, fails, cpu


def main(args, cijoe):
    devices = cijoe.getconf("devices")
    if not devices:
        log.error("Failed: no 'devices' defined in config")
        return 1
    all_uris = [d["pci_addr"] for d in devices]

    backends = cfg(args, cijoe, "backends")
    iosizes = cfg(args, cijoe, "iosizes")
    qdepths = cfg(args, cijoe, "qdepths")
    ndevs_list = cfg(args, cijoe, "ndevs")
    cpumasks = cfg(args, cijoe, "cpumasks")
    iopattern = cfg(args, cijoe, "iopattern", "randread")
    runtime = cfg(args, cijoe, "runtime", 10)
    repetitions = cfg(args, cijoe, "repetitions", 10)
    label = cfg(args, cijoe, "label")

    missing = [
        n
        for n, v in [
            ("backends", backends), ("iosizes", iosizes), ("qdepths", qdepths),
            ("ndevs", ndevs_list), ("cpumasks", cpumasks), ("label", label),
        ]
        if not v
    ]
    if missing:
        log.error(f"Failed: missing required parameter(s): {', '.join(missing)}")
        return 1

    results_dir = Path(args.output) / "xnvmeperf" / label
    cijoe.run_local(f"mkdir -p {results_dir}")

    for be, iosize, qdepth, ndevs, cpumask in product(
        backends, iosizes, qdepths, ndevs_list, cpumasks
    ):
        if ndevs > len(all_uris):
            log.error(f"Failed: need {ndevs} devices, config has {len(all_uris)}")
            return 1
        uris = " ".join(all_uris[:ndevs])
        key = point_key(be, iosize, qdepth, ndevs, cpumask, iopattern)

        for rep in range(repetitions):
            res_path = results_dir / f"{key}-rep{rep}.json"

            command = (
                f"/usr/bin/time xnvmeperf run {uris}"
                f" --iosize {iosize} --qdepth {qdepth} --be {be}"
                f" --runtime {runtime} --iopattern {iopattern} --cpumask {cpumask}"
            )

            err, state = cijoe.run(command)
            if err:
                log.error(f"Failed: xnvmeperf for {res_path.name}")
                return err

            iops, mibs, fails, cpu = parse_output(state.output())
            if iops is None or cpu is None:
                log.error(f"Failed: could not parse output for {res_path.name}")
                return 1
            if fails and fails > 0:
                log.error(f"Failed: {fails:.0f} failed I/Os for {res_path.name}")
                return 1

            result = {
                "label": label,
                "key": key,
                "backend": be,
                "iosize": iosize,
                "qdepth": qdepth,
                "ndevs": ndevs,
                "cpumask": cpumask,
                "iopattern": iopattern,
                "runtime": runtime,
                "rep": rep,
                "iops": iops,
                "mibs": mibs,
                "cpu": cpu,
                "efficiency": iops / cpu if cpu else None,
            }
            with open(res_path, "w") as f:
                json.dump(result, f, indent=2)

            log.info(f"{res_path.name}: iops={iops:.0f} mibs={mibs:.0f} cpu={cpu:.0f}%")

    return 0

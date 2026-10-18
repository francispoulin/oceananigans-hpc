#!/usr/bin/env python3
"""Summarize Oceananigans benchmark-suite JSON files as one Markdown table.

    python3 tools/summarize_benchmarks.py results/*.json $SCRATCH/software/Oceananigans.jl/benchmarking/results/*.json

Each JSON file is one job: a list with one record per MPI rank. For each job the table shows:
  - fastest and median time per step (the slowest rank's, since all ranks wait for it) and
    the slowest window, so the spread between windows is visible;
  - GPU memory per rank (largest rank) and bytes per cell, when the suite recorded it;
  - strong-scaling efficiency against the 1-GPU run of the same grid, and weak-scaling
    efficiency against a 1-GPU run of the same benchmark with the same cells per GPU (within 5%).
Efficiencies use the median, which is what a long production run sees; the fastest window is
what the suite reports. Standard library only (runs on any login node).
"""
import json
import re
import sys
from pathlib import Path


def load(path):
    data = json.loads(Path(path).read_text())
    recs = data if isinstance(data, list) else [data]
    recs = [r for r in recs if "time_per_step_seconds" in r]
    if not recs:
        return None
    r0 = recs[0]
    m = re.search(r"_(\d+)x(\d+)x(\d+)_", r0["name"])
    size = tuple(int(v) for v in m.groups()) if m else tuple(r0["grid_size"])
    cells = size[0] * size[1] * size[2]
    ngpu = len(recs)
    hosts = {r.get("metadata", {}).get("hostname") for r in recs} - {None}
    mem = [r.get("gpu_memory_used") for r in recs if r.get("gpu_memory_used")]
    family = re.sub(r"_\d+x\d+x\d+_", "_", r0["name"])
    return dict(
        file=Path(path).name,
        family=family,
        size=size,
        cells=cells,
        ngpu=ngpu,
        nodes=len(hosts) if len(hosts) > 0 else None,
        per_gpu=cells / ngpu,
        fast=max(r["time_per_step_seconds"] for r in recs),
        median=max(r.get("time_per_step_median_seconds", r["time_per_step_seconds"]) for r in recs),
        slow=max(r.get("time_per_step_max_seconds", r["time_per_step_seconds"]) for r in recs),
        mem=max(mem) if mem else None,
        float=r0.get("float_type", ""),
        date=r0.get("metadata", {}).get("timestamp", "")[:10],
    )


def main(paths):
    # A shell pattern that matches nothing (e.g. wk_*.json before any weak-scaling run has finished)
    # arrives here unexpanded: say so and carry on with the files that exist.
    missing = [p for p in paths if not Path(p).is_file()]
    for p in missing:
        print(f"(no file: {p})", file=sys.stderr)
    jobs = [j for j in (load(p) for p in paths if p not in missing) if j]
    if not jobs:
        sys.exit("no benchmark results found")
    jobs.sort(key=lambda j: (j["family"], j["cells"], j["ngpu"]))
    singles = [j for j in jobs if j["ngpu"] == 1]

    def strong(j):
        ref = [s for s in singles if s["family"] == j["family"] and s["size"] == j["size"]]
        return ref[0]["median"] / (j["ngpu"] * j["median"]) if ref else None

    def weak(j):
        ref = [s for s in singles if s["family"] == j["family"]
               and abs(s["per_gpu"] / j["per_gpu"] - 1) < 0.05]
        return ref[0]["median"] / j["median"] if ref else None

    pct = lambda x: f"{100 * x:.0f}%" if x is not None else "–"
    print("| Grid | GPUs | Nodes | Cells per GPU | Fastest (s/step) | Median | Slowest window "
          "| Strong eff. | Weak eff. | GPU memory per rank (GiB) | Bytes per cell | Date | File |")
    print("| --- " * 13 + "|")
    for j in jobs:
        mem = f"{j['mem'] / 2**30:.1f}" if j["mem"] else "–"
        bpc = f"{j['mem'] / j['per_gpu']:.0f}" if j["mem"] else "–"
        print(f"| {'×'.join(map(str, j['size']))} | {j['ngpu']} | {j['nodes'] or '–'} "
              f"| {j['per_gpu'] / 1e6:.1f} M | {j['fast']:.4f} | {j['median']:.4f} | {j['slow']:.4f} "
              f"| {pct(strong(j)) if j['ngpu'] > 1 else '–'} | {pct(weak(j)) if j['ngpu'] > 1 else '–'} "
              f"| {mem} | {bpc} | {j['date']} | `{j['file']}` |")
    fams = sorted({j["family"] for j in jobs})
    print()
    for f in fams:
        print(f"- `{f}`")


if __name__ == "__main__":
    if not sys.argv[1:] or sys.argv[1] in ("-h", "--help"):
        sys.exit(print(__doc__))
    main(sys.argv[1:])

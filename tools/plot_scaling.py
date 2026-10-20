#!/usr/bin/env python3
"""Plot hydrostatic strong scaling (time per step and efficiency vs GPUs) from the tables in
results/hydrostatic_scaling.md, so the numbers live in one place and the figure follows them.

    python3 tools/plot_scaling.py                     # writes results/hydrostatic_scaling.png
    python3 tools/plot_scaling.py -o /tmp/scaling.png

Reads the strong-scaling table (one column per cluster and setting, "time (efficiency)" cells;
"pending" and blank cells are skipped) and the Oct 2 column of the Nibi before/after table.
Efficiency is recomputed from the times: time on 1 GPU / (N x time on N GPUs), against each
cluster's own 1-GPU run. Colour = cluster, line style = MPI (solid) or NCCL (dashed); Nibi before
the two GPU settings is grey and dotted. Needs matplotlib (any Python 3 with it; not used by CI).
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAGE = ROOT / "results/hydrostatic_scaling.md"
COLOURS = {"Nibi": "#2a78d6", "Trillium": "#eb6834", "Rorqual": "#1baf7a"}   # validated categorical slots 1-3
MARKERS = {"Nibi": "o", "Trillium": "s", "Rorqual": "^"}
NUMBER = re.compile(r"^\s*([0-9]*\.[0-9]+|[0-9]+)")


def table_after(text, heading):
    """Rows (lists of cells) of the first Markdown table after the line starting with `heading`."""
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith(heading))
    rows = []
    for line in lines[start + 1:]:
        if line.startswith("|"):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
        elif rows:
            break
    return rows[0], [r for r in rows[2:]]          # header, data (skip the --- row)


def series_from(text):
    """{(cluster, setting): {gpus: seconds}} from the strong-scaling table, plus Nibi before."""
    header, rows = table_after(text, "## Strong scaling")
    series = {}
    for j, name in enumerate(header):
        parts = name.split()
        if len(parts) != 2 or parts[1] not in ("MPI", "NCCL"):
            continue
        for row in rows:
            m = NUMBER.match(row[j])
            if m:
                series.setdefault((parts[0], parts[1]), {})[int(row[0])] = float(m.group(1))
    header, rows = table_after(text, "**Nibi before and after the two settings**")
    j = header.index("Oct 2")
    series[("Nibi", "before")] = {int(r[0]): float(NUMBER.match(r[j]).group(1)) for r in rows}
    return series


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default=str(ROOT / "results/hydrostatic_scaling.png"))
    args = ap.parse_args()
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    series = series_from(PAGE.read_text())
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False,
                         "axes.edgecolor": "#8a8a85", "xtick.color": "#5a5a55", "ytick.color": "#5a5a55",
                         "axes.labelcolor": "#2b2b28", "text.color": "#2b2b28"})
    fig, (ax_t, ax_e) = plt.subplots(1, 2, figsize=(10, 4.2), constrained_layout=True)
    gpus_all = sorted({n for s in series.values() for n in s})

    for (cluster, setting), pts in sorted(series.items(), key=lambda kv: (kv[0][1] == "before", kv[0])):
        if 1 not in pts and setting != "NCCL":
            continue
        base = series.get((cluster, "MPI" if setting == "NCCL" else setting), {}).get(1)
        n = sorted(pts)
        t = [pts[k] for k in n]
        eff = [100 * base / (k * pts[k]) for k in n]
        if setting == "before":
            style = dict(color="#9a9a94", linestyle=":", marker="o", markerfacecolor="white",
                         label="Nibi, before the GPU settings (Oct 2)")
        else:
            style = dict(color=COLOURS[cluster], marker=MARKERS[cluster],
                         linestyle="-" if setting == "MPI" else "--",
                         markerfacecolor=COLOURS[cluster] if setting == "MPI" else "white",
                         label=f"{cluster} {setting}")
        style.update(linewidth=2, markersize=7, markeredgewidth=1.5)
        ax_t.plot(n, t, **style)
        ax_e.plot(n, eff, **style)

    t1 = series[("Nibi", "MPI")][1]
    ax_t.plot(gpus_all, [t1 / k for k in gpus_all], color="#c8c8c2", linewidth=1, zorder=0)
    ax_t.annotate("ideal", (gpus_all[-1], t1 / gpus_all[-1]), textcoords="offset points", xytext=(4, -4),
                  color="#8a8a85", fontsize=9)
    for ax in (ax_t, ax_e):
        ax.set_xscale("log", base=2)
        ax.set_xticks(gpus_all, [str(k) for k in gpus_all])
        ax.set_xlabel("GPUs (H100)")
        ax.grid(True, color="#e6e6e1", linewidth=0.8)
        ax.set_axisbelow(True)
    ax_t.set_yscale("log")
    ax_t.set_yticks([0.05, 0.1, 0.2, 0.5, 1.0], ["0.05", "0.1", "0.2", "0.5", "1"])
    ax_t.minorticks_off()
    ax_t.set_ylabel("Time per step (s)")
    ax_t.set_title("Time per step", loc="left", fontweight="bold")
    ax_e.set_ylabel("Strong-scaling efficiency (%)")
    ax_e.set_ylim(40, 103)
    ax_e.set_title("Efficiency (vs each cluster's 1 GPU)", loc="left", fontweight="bold")
    ax_e.legend(loc="lower left", frameon=False, fontsize=9)
    fig.suptitle("Oceananigans hydrostatic earth_ocean, 1440 × 720 × 200 (1/4°), Float64", x=0.01,
                 ha="left", fontsize=11)
    fig.savefig(args.output, dpi=150)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    if sys.argv[1:2] in (["-h"], ["--help"]):
        sys.exit(print(__doc__))
    main()

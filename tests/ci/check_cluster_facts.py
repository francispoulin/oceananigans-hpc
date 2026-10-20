"""Check that the docs state the same cluster facts as jobs/gpu_request.sh, the one place where they
are written, and that no job script or example uses --gpus-per-task.

Runs on every pull request (.github/workflows/checks.yml) and anywhere with bash and Python 3:
    python3 tests/ci/check_cluster_facts.py

1. docs/drac.md, step 6 ("Without the wrapper"): every cell must equal the Slurm options that
   jobs/submit_gpu.sh prints for that cluster and number of GPUs ("same" = the cell to its left).
2. GPUs per node in the README's machine table and in the table at the top of docs/drac.md must
   equal default_gpus_per_node for each cluster.
3. --gpus-per-task= may be explained in prose but never used: not in a #SBATCH line or a command
   of any script, and not inside a code block of any doc.
"""
import os
import pathlib
import re
import subprocess
import sys

if sys.argv[1:2] in (["-h"], ["--help"]):
    sys.exit(print(__doc__))
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
fails = []


def bash(cmd, cluster):
    env = dict(os.environ, CC_CLUSTER=cluster, OCEAN_HPC_ROOT=str(root), DRYRUN="1",
               OCEAN_JOB_DIR=tempfile.mkdtemp())
    return subprocess.run(["bash", "-c", cmd], cwd=root, env=env, capture_output=True,
                          text=True).stdout.strip()


def slurm_options(text):
    keys = ("--nodes", "--ntasks-per-node", "--gpus-per-node", "--mem")
    return {o for o in text.split() if o.split("=")[0] in keys}


def gpus_per_node(cluster):
    return int(bash("source jobs/gpu_request.sh; default_gpus_per_node", cluster))


def check(ok, what):
    print(("PASS  " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


# 1. Step-6 table in docs/drac.md
drac = (root / "docs/drac.md").read_text()
after = drac[drac.index("**Without the wrapper.**"):].splitlines()
start = next(i for i, r in enumerate(after) if r.startswith("|"))    # only the first table after it
end = next((i for i in range(start, len(after)) if not after[i].startswith("|")), len(after))
section = "\n".join(after[start:end])
rows = [r for r in section.splitlines() if re.match(r"^\| \d+ \|", r)]
header = next(r for r in section.splitlines() if r.startswith("| GPUs |"))
columns = [c.strip() for c in header.strip("|").split("|")][1:]
column_clusters = [[w.lower() for w in re.findall(r"Nibi|Fir|Rorqual|Trillium", c)] for c in columns]
check(len(rows) >= 3 and column_clusters, f"step-6 table found ({len(rows)} rows)")
for row in rows:
    cells = [c.strip() for c in row.strip("|").split("|")]
    n, cells = cells[0], cells[1:]
    previous = None
    for cell, clusters in zip(cells, column_clusters):
        doc = slurm_options(previous if cell == "same" else cell.replace("`", ""))
        previous = cell.replace("`", "") if cell != "same" else previous
        for cluster in clusters:
            script = slurm_options(bash(f"bash jobs/submit_gpu.sh jobs/checks.sh {n}", cluster))
            check(doc == script, f"docs/drac.md step 6, {cluster}, {n} GPUs: "
                  + ("matches submit_gpu.sh" if doc == script else f"docs {sorted(doc)} vs script {sorted(script)}"))

# 2. GPUs per node in the README and at the top of docs/drac.md
readme = (root / "README.md").read_text()
for cluster in ("nibi", "fir", "rorqual", "trillium"):
    g = gpus_per_node(cluster)
    m = re.search(rf"^\| {cluster}[^|]*\| (\d+) × ", readme, re.I | re.M)
    check(bool(m) and int(m.group(1)) == g, f"README machine table, {cluster}: {g} GPUs per node")
    m = re.search(rf"^\| \[{cluster}\][^|]*\| (\d+) \|", drac, re.I | re.M)
    check(bool(m) and int(m.group(1)) == g, f"docs/drac.md overview table, {cluster}: {g} GPUs per node")

# 3. --gpus-per-task never used
files = subprocess.run(["git", "ls-files", "*.sh", "*.md"], cwd=root, capture_output=True,
                       text=True).stdout.split()
used = []
for name in files:
    if name.startswith(("results/", "tests/ci/")) or name == "docs/drac_to_post.m":
        continue
    in_code = False
    for lineno, line in enumerate((root / name).read_text().splitlines(), 1):
        if name.endswith(".md") and line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        if "--gpus-per-task=" not in line:
            continue
        if name.endswith(".sh"):
            code = line.split("#", 1)[0] if not line.startswith("#SBATCH") else line
            if "--gpus-per-task=" in code:
                used.append(f"{name}:{lineno}")
        elif in_code:
            used.append(f"{name}:{lineno}")
check(not used, "--gpus-per-task not used in scripts or doc examples" + (f": {used}" if used else ""))

print(f"{len(fails)} failure(s)")
sys.exit(1 if fails else 0)

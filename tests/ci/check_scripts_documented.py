"""Check that every script is documented: listed in docs/scripts.md, with a usage line in its header,
and (for scripts that are run, not sourced) answering -h with that header.

Runs on every pull request (.github/workflows/checks.yml) and anywhere with bash and Python 3:
    python3 tests/ci/check_scripts_documented.py
"""
import os
import pathlib
import re
import subprocess
import sys

if sys.argv[1:2] in (["-h"], ["--help"]):
    sys.exit(print(__doc__))

root = pathlib.Path(__file__).resolve().parents[2]
patterns = ["env/*.sh", "jobs/*.sh", "setup/*.sh", "tools/*.sh", "tools/*.py", "tools/*.jl",
            "tests/ci/*.sh", "tests/ci/*.py"]
scripts = subprocess.run(["git", "ls-files", *patterns], cwd=root, capture_output=True,
                         text=True).stdout.split()
sourced = {"env/ocean_setup.sh", "env/drac.sh", "env/fluidsgpu.sh", "jobs/gpu_request.sh"}
page = (root / "docs/scripts.md").read_text()
usage = re.compile(r"^(#|\s|\"\"\"|    )*.*\b(bash|sbatch|source|python3|julia)\s+\S", re.M)
fails = []


def check(ok, what):
    print(("PASS  " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


env = {k: v for k, v in os.environ.items() if k != "OCEAN_HPC_ROOT"}
for name in scripts:
    listed = name in page or (name.startswith("tests/ci/") and pathlib.Path(name).name in page)
    text = (root / name).read_text()
    header = "\n".join(text.splitlines()[:40])
    has_usage = bool(usage.search(header))
    ok = listed and has_usage
    why = [w for w, bad in (("not in docs/scripts.md", not listed), ("no usage in header", not has_usage)) if bad]
    if name.endswith((".sh", ".py")) and name not in sourced:
        runner = "bash" if name.endswith(".sh") else sys.executable
        r = subprocess.run([runner, name, "-h"], cwd=root, env=env, capture_output=True, text=True,
                           timeout=30)
        lines = r.stdout.splitlines()     # the header, without its #SBATCH directives
        helps = r.returncode == 0 and len(lines) >= 2 and not any(l.startswith("SBATCH") for l in lines)
        ok = ok and helps
        if not helps:
            why.append("-h does not print the header")
    check(ok, name + (": " + ", ".join(why) if why else ""))

print(f"{len(scripts)} scripts, {len(fails)} failure(s)")
sys.exit(1 if fails else 0)

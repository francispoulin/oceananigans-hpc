"""Check that every machine gets the same Julia: the julia_version of Manifest.toml and
viz/Manifest.toml, and the julia module loaded by env/drac.sh (the Alliance clusters), all agree.
pelee and rondeau read the version from Manifest.toml (env/fluidsgpu.sh, setup/install_julia.sh).

Runs on every pull request (.github/workflows/checks.yml) and anywhere with Python 3:
    python3 tests/ci/check_julia_version.py
"""
import pathlib
import re
import sys

if sys.argv[1:2] in (["-h"], ["--help"]):
    sys.exit(print(__doc__))

root = pathlib.Path(__file__).resolve().parents[2]
found = {}
for manifest in ["Manifest.toml", "viz/Manifest.toml"]:
    m = re.search(r'^julia_version = "([^"]+)"$', (root / manifest).read_text(), re.M)
    found[manifest] = m.group(1) if m else None
m = re.search(r"^module load julia/(\S+)", (root / "env/drac.sh").read_text(), re.M)
found["env/drac.sh (julia module)"] = m.group(1) if m else None
m = re.search(r"Manifest\.toml", (root / "env/fluidsgpu.sh").read_text())
found["env/fluidsgpu.sh reads Manifest.toml"] = found["Manifest.toml"] if m else None

want = found["Manifest.toml"]
fails = 0
for where, v in found.items():
    ok = v is not None and v == want
    print(("PASS  " if ok else "FAIL  ") + f"{where}: {v}" + ("" if ok else f" (Manifest.toml: {want})"))
    fails += not ok
print(f"{fails} failure(s)")
sys.exit(fails > 0)

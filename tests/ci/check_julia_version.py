"""Check that every machine gets the same Julia: Manifest.toml and viz/Manifest.toml were made with
the same julia_version; env/julia.sh reads that version from Manifest.toml; both machine files
(env/drac.sh, env/fluidsgpu.sh) take Julia from env/julia.sh; and env/drac.sh loads no julia module
of its own (a fixed version there would drift from the Manifest).

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
julia_sh = (root / "env/julia.sh").read_text()
found["env/julia.sh reads Manifest.toml"] = found["Manifest.toml"] if "Manifest.toml" in julia_sh else None
for env in ["env/drac.sh", "env/fluidsgpu.sh"]:
    text = (root / env).read_text()
    found[f"{env} sources env/julia.sh"] = found["Manifest.toml"] if re.search(r"^source .*env/julia\.sh", text, re.M) else None
m = re.search(r"^\s*module load julia\S*", (root / "env/drac.sh").read_text(), re.M)
found["env/drac.sh loads no julia module itself"] = None if m else found["Manifest.toml"]

want = found["Manifest.toml"]
fails = 0
for where, v in found.items():
    ok = v is not None and v == want
    print(("PASS  " if ok else "FAIL  ") + f"{where}: {v}" + ("" if ok else f" (Manifest.toml: {want})"))
    fails += not ok
print(f"{fails} failure(s)")
sys.exit(fails > 0)

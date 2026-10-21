#!/bin/bash
# Installs the official Julia release that the platform's Manifest.toml was made with (its
# julia_version, e.g. 1.10.10), on any machine: every machine then runs the same binary, and a new
# Julia version needs no new module. Once per machine (pelee and rondeau share one), on a login node
# or a server with internet, from anywhere:
#
#     bash /path/to/oceananigans-hpc/setup/install_julia.sh
#
# Installs to $OCEAN_SOFTWARE_DIR/julia-<version>, as env/julia.sh defines it (default: a folder
# "software" next to the Julia depot, e.g. /project/<group>/<user>/software on the Alliance), after
# checking the download against julialang.org's SHA-256 checksums. The environment (ocean_setup) then
# puts that julia on PATH instead of the julia module. Nothing is overwritten or deleted: an existing
# installation is left alone. About 1 GB; read-only once installed (Trillium jobs can use it).
# Alliance clusters: the binaries are then adapted with the Alliance's setrpaths.sh, so they use the
# software stack's own loader, as the julia module does; otherwise the cluster's libmpi can't find
# the libraries it needs (Oct 21: "libze_loader.so.1: cannot open shared object file"). Only the
# programs' loader and library search paths change, not the code. Rerunning on an installation made
# before this step adapts it.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The version and the folder exactly as the environment sees them (env/julia.sh, via ocean_setup).
# This process only: the caller's shell is not changed. Its "not installed yet" warning is expected.
set +eu
source "$ROOT/env/ocean_setup.sh" >/dev/null 2>&1
set -eu
version="${OCEAN_JULIA_VERSION:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install_julia.sh: no julia_version in $ROOT/Manifest.toml (or no environment for this machine)" >&2; exit 1; }
[[ -n "${OCEAN_SOFTWARE_DIR:-}" ]] || { echo "install_julia.sh: OCEAN_SOFTWARE_DIR not set by env/julia.sh" >&2; exit 1; }
target="$OCEAN_SOFTWARE_DIR/julia-$version"

# Alliance: point the binaries at the software stack's loader (see the header). Elsewhere: nothing.
adapt() {   # adapt <julia folder>
    command -v setrpaths.sh >/dev/null || return 0
    local interp
    interp="$(readelf -l "$1/bin/julia" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
    if [[ "$interp" == /cvmfs/* ]]; then echo "   loader: $interp (already adapted)"; return 0; fi
    echo "== Adapt to the Alliance software stack (setrpaths.sh)"
    setrpaths.sh --path "$1" --add_origin >/dev/null
    interp="$(readelf -l "$1/bin/julia" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
    [[ "$interp" == /cvmfs/* ]] || { echo "install_julia.sh: setrpaths.sh did not change the loader ($interp)" >&2; return 1; }
    echo "   loader: $interp"
}

if [[ -x "$target/bin/julia" ]]; then
    echo "Already installed: $("$target/bin/julia" --startup-file=no --version) in $target"
    adapt "$target"
    exit 0
fi
[[ -e "$target" ]] && { echo "install_julia.sh: $target exists but has no bin/julia; look at it, remove it yourself, and rerun" >&2; exit 1; }

tarball="julia-$version-linux-x86_64.tar.gz"
url="https://julialang-s3.julialang.org/bin/linux/x64/${version%.*}/$tarball"
sums="https://julialang-s3.julialang.org/bin/checksums/julia-$version.sha256"
mkdir -p "$OCEAN_SOFTWARE_DIR"
tmp="$(mktemp -d "$OCEAN_SOFTWARE_DIR/.julia-$version.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT                    # only the temporary download folder

echo "== 1. Download Julia $version ($url)"
curl -fL --retry 3 -o "$tmp/$tarball" "$url"
curl -fsSL --retry 3 -o "$tmp/sums" "$sums"

echo "== 2. Check SHA-256"
want="$(awk -v f="$tarball" '$2 == f {print $1}' "$tmp/sums")"
have="$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
[[ -n "$want" && "$want" == "$have" ]] || { echo "install_julia.sh: checksum mismatch (want '$want', have '$have'); nothing installed" >&2; exit 1; }
echo "OK $have"

echo "== 3. Unpack to $target"
tar -xzf "$tmp/$tarball" -C "$tmp"
adapt "$tmp/julia-$version"                  # before it is in place: installed means ready
mv "$tmp/julia-$version" "$target"
"$target/bin/julia" --startup-file=no --version

echo
echo "Done. Log in again or source ocean_setup (it now uses this julia; check_env shows which)."
echo "Packages are recompiled for it the first time (the depot keeps each Julia's files apart):"
echo "tools/run_tests.sh does that on its own, or by hand: bash setup/setup.sh"

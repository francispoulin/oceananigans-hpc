#!/bin/bash
# Installs the official Julia release that the platform's Manifest.toml was made with (its
# julia_version, e.g. 1.10.10), for machines whose modules do not offer it (pelee and rondeau).
# Once per version, on a machine with internet; pelee and rondeau share the drive, so either:
#
#     bash /path/to/oceananigans-hpc/setup/install_julia.sh
#
# Installs to $OCEAN_SOFTWARE_DIR/julia-<version> (default /mnt/autofs/bow.math/scratch/$USER/software,
# else ~/software), after checking the download against julialang.org's SHA-256 checksums.
# env/fluidsgpu.sh then puts that julia on PATH. Nothing is overwritten or deleted: an existing
# installation is left alone. The Alliance clusters use their julia module instead (env/drac.sh).

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$ROOT/Manifest.toml")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install_julia.sh: no julia_version in $ROOT/Manifest.toml" >&2; exit 1; }
if [[ -z "${OCEAN_SOFTWARE_DIR:-}" ]]; then
    if [[ -d "/mnt/autofs/bow.math/scratch/$USER" ]]; then OCEAN_SOFTWARE_DIR="/mnt/autofs/bow.math/scratch/$USER/software"
    else OCEAN_SOFTWARE_DIR="$HOME/software"; fi
fi
target="$OCEAN_SOFTWARE_DIR/julia-$version"
if [[ -x "$target/bin/julia" ]]; then
    echo "Already installed: $("$target/bin/julia" --startup-file=no --version) in $target"
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
mv "$tmp/julia-$version" "$target"
"$target/bin/julia" --startup-file=no --version

echo
echo "Done. Source ocean_setup again (it now uses this julia), then rerun the setup, which"
echo "recompiles the packages for this version (the depot keeps each version's files apart):"
echo "    bash setup/setup.sh && bash setup/setup_viz.sh && bash setup/setup_nccl_env.sh --this-machine"
echo "    bash tools/check_env.sh && bash tools/run_tests.sh"

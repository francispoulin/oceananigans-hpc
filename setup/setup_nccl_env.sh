#!/bin/bash
# Make a SEPARATE Julia environment with NCCL.jl added, to test Oceananigans' NCCLDistributed
# without touching the main environment: same packages and versions as this repository's
# Manifest, plus NCCL. Once per machine (needs internet: run it on a login node / pelee):
#
#     bash setup/setup_nccl_env.sh [DIR]     # default DIR: $OCEAN_HPC_ROOT/envs/nccl
#
# Then run with it:  bash tools/run_local.sh --project envs/nccl ...  (envs/ is not committed).
# Delete the folder to remove it; nothing else changes.
#
# On EACH OTHER machine that shares this folder (e.g. rondeau after setting up on pelee), run once,
# with a single process, before any multi-GPU run:
#
#     bash setup/setup_nccl_env.sh --this-machine
#
# NCCL's library is chosen per machine from the GPU driver (pelee and rondeau pick different CUDA
# builds), so it may need downloading; and two MPI ranks compiling NCCL at the same time fail.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
OCEAN_HPC_ROOT="${OCEAN_HPC_ROOT:-${OCEANANIGANS_DRAC_ROOT:-}}"   # old name: environments set up before the rename
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
ROOT="$OCEAN_HPC_ROOT"
if [[ "$1" == "--this-machine" ]]; then
    DIR="${2:-$ROOT/envs/nccl}"
    [[ -f "$DIR/Project.toml" ]] || { echo "no environment in $DIR: run without --this-machine first"; exit 1; }
    echo "== Download what this machine needs and compile (one process)"
    julia --project="$DIR" -e 'using Pkg; Pkg.instantiate()'
    julia --project="$DIR" -e '
        using Oceananigans, CUDA, NCCL
        ok = Base.get_extension(Oceananigans, :OceananigansNCCLExt) !== nothing
        println(ok ? "OK: OceananigansNCCLExt loaded on $(gethostname())" : "FAIL: OceananigansNCCLExt did not load")
        ok || exit(1)'
    exit 0
fi
DIR="${1:-$ROOT/envs/nccl}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
cp "$ROOT/Project.toml" "$ROOT/Manifest.toml" "$DIR/"

echo "== 1. Add NCCL.jl to $DIR, keeping every other package at its current version"
julia --project="$DIR" -e 'using Pkg; Pkg.add(Pkg.PackageSpec(name="NCCL"); preserve=Pkg.PRESERVE_ALL)'

echo "== 2. System MPI for this environment (as for any project folder)"
bash "$ROOT/setup/configure_mpi.sh" "$DIR"

echo "== 3. Check versions and that Oceananigans' NCCL extension loads"
julia --project="$DIR" -e '
    using Pkg; Pkg.status(["Oceananigans", "CUDA", "NCCL", "NCCL_jll"]; mode=Pkg.PKGMODE_MANIFEST)
    using Oceananigans, CUDA, NCCL
    ext = Base.get_extension(Oceananigans, :OceananigansNCCLExt)
    println(ext === nothing ? "FAIL: OceananigansNCCLExt did not load" : "OK: OceananigansNCCLExt loaded")
    ext === nothing && exit(1)'

echo "Done. Use: bash tools/run_local.sh --project $DIR ... (Oceananigans version must match the main environment above)."

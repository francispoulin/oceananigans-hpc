#!/bin/bash
# Slurm job for Trillium's debug queue (one node, 4 H100s, ~15 min): runs diag_hydro_split.jl on
# 1 and 4 GPUs for four variants of the platform's hydrostatic channel, plus the base case on 2
# GPUs, and compares each with its 1-GPU run. Uses the candidate environment that
# tools/test_branch.sh left in the test worktree (Oceananigans 0.118.2). From the folder that holds
# both files (on $SCRATCH, so the job can write its log there):
#
#     sbatch diag_hydro_split.sh
#
#   base   substeps 20, Nx 128 (32 cells per rank on 4 GPUs), SplitRungeKutta3: the failing test
#   sub10  substeps 10 (a shorter barotropic halo reach)
#   nx256  Nx 256 (64 cells per rank)
#   ab2    QuasiAdamsBashforth2 instead of SplitRungeKutta3
#SBATCH --job-name=diag_hydro
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
#SBATCH --partition=debug_full_node
#SBATCH --time=0:30:00
#SBATCH --output=%x_%j.out

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
WT="${WT:-/project/def-fpoulin/fpoulin/software/oceananigans-hpc-test}"
source "$WT/env/ocean_setup.sh" > /dev/null || exit 1
out="$SCRATCH/diag_hydro_${SLURM_JOB_ID:-test}"; mkdir -p "$out"
J=(julia --project="$WT" "$SLURM_SUBMIT_DIR/diag_hydro_split.jl")
echo "Oceananigans $(julia --project="$WT" -e 'using Oceananigans; print(pkgversion(Oceananigans))') from $WT; files in $out"
for c in "base 20 128 SplitRungeKutta3" "sub10 10 128 SplitRungeKutta3" "nx256 20 256 SplitRungeKutta3" "ab2 20 128 QuasiAdamsBashforth2"; do
    set -- $c
    for n in 1 4; do srun --exact --ntasks=$n --cpu-bind=none "${J[@]}" run "$out" "$@" || echo "$1 on $n GPU(s) FAILED"; done
    "${J[@]}" compare "$out" "$1" 4
    if [[ $1 == base ]]; then
        srun --exact --ntasks=2 --cpu-bind=none "${J[@]}" run "$out" "$@" && "${J[@]}" compare "$out" base 2
    fi
done

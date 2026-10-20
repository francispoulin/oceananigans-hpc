#!/bin/bash
# Set up the Oceananigans benchmark suite (benchmarking/ in an Oceananigans checkout) on any
# Alliance cluster (Nibi included), matching the version used for the Nibi scaling results, plus NCCL for
# MPI-vs-NCCL comparisons. Once per cluster, on a LOGIN node (needs internet), after ocean_setup:
#
#     bash setup/setup_benchmark_suite.sh          # checkout in $SCRATCH/software/Oceananigans.jl
#     BENCH_ROOT=/other/path bash setup/setup_benchmark_suite.sh
#
# Steps: clone Oceananigans at commit 8743c40d0 (v0.113.5 + 5 commits, as on Nibi); apply
# setup/patches/oceananigans_benchmarking_8743c40d0.patch (GPU memory for distributed runs, as on
# Nibi; OPAL_PREFIX from OCEAN_MPI_ROOT; new --comm MPI|NCCL option); configure_mpi.sh on
# benchmarking/; add NCCL.jl to it, with the GPU package versions of envs/nccl (so run
# setup/setup_nccl_env.sh first). (Nibi's original hand-edited checkout of Oct 2 is kept as
# $SCRATCH/software/Oceananigans.jl.nibi-2026-10-02; this script replaced it on Oct 15.)
# Then: jobs/benchmark.sh (COMM=NCCL for NCCL) or jobs/submit_hydro_nccl.sh.

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
set -eo pipefail
: "${OCEAN_HPC_ROOT:?run ocean_setup first}"
ROOT="$OCEAN_HPC_ROOT"
BENCH_ROOT="${BENCH_ROOT:-$SCRATCH/software/Oceananigans.jl}"
COMMIT=8743c40d01555030bc776110ba08edee0b041e5b
PATCH="$ROOT/setup/patches/oceananigans_benchmarking_8743c40d0.patch"

echo "== 1. Oceananigans checkout at $COMMIT in $BENCH_ROOT"
if [[ ! -d "$BENCH_ROOT/.git" ]]; then
    mkdir -p "$(dirname "$BENCH_ROOT")"
    git clone https://github.com/CliMA/Oceananigans.jl.git "$BENCH_ROOT"
fi
cd "$BENCH_ROOT"
if grep -q -- '"--comm"' benchmarking/run_benchmarks.jl 2>/dev/null; then    # our patch adds --comm
    echo "   suite patch already applied"
else
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || {
        echo "ERROR: $BENCH_ROOT has local changes and the suite patch is not applied:"; git status --short; exit 1; }
    git cat-file -e "$COMMIT^{commit}" 2>/dev/null || { echo "   fetching (existing clone without $COMMIT)"; git fetch -q origin; }
    git checkout -q "$COMMIT"
    git apply "$PATCH"
    echo "   checked out $(git log --oneline -1) and applied the suite patch"
fi

# GPU memory in the results: the suite reads the size of CUDA.jl's memory pool, which is `nothing`
# when the pool is off (JULIA_CUDA_MEMORY_POOL=none, set by env/drac.sh since Oct 15, 2026 for
# fast GPU-to-GPU MPI), and then fails when it writes the results ("Cannot convert Nothing to Int64").
# Use the memory in use on the device instead when there is no pool. Idempotent.
U="$BENCH_ROOT/benchmarking/src/utils.jl"
if ! grep -q "gpu_memory_in_use" "$U"; then
    sed -i 's/CUDACore\.MemoryInfo()\.pool_used_bytes/gpu_memory_in_use()/g' "$U"
    cat >> "$U" <<'JL'

# Added by oceananigans-hpc setup/setup_benchmark_suite.sh: works with the memory pool off too.
function gpu_memory_in_use()
    m = CUDACore.MemoryInfo()
    p = m.pool_used_bytes
    return p isa Integer ? Int(p) : Int(m.total_bytes - m.free_bytes)
end
JL
    echo "   GPU-memory fix applied to src/utils.jl"
fi

echo "== 2. System MPI for benchmarking/ (configure_mpi.sh)"
bash "$ROOT/setup/configure_mpi.sh" "$BENCH_ROOT/benchmarking"

echo "== 3. Add NCCL.jl to benchmarking/, with the GPU packages of envs/nccl (known to work here)"
# NCCL.jl 0.1.3 needs CUDA.jl >= 6.4 (GPUToolbox 3), but the suite allows only CUDA 6.0-6.1, so
# widen that; and the newest GPU stack may not precompile with Julia 1.10 (GPUCompiler 2.14 failed
# on Fir), so take the versions from this repository's NCCL environment instead of the newest.
REF="$ROOT/envs/nccl/Manifest.toml"
[[ -f "$REF" ]] || { echo "ERROR: no $REF: run bash setup/setup_nccl_env.sh first"; exit 1; }
sed -i 's/^CUDA = "5, 6.0 - 6.1"$/CUDA = "5, 6"/' "$BENCH_ROOT/benchmarking/Project.toml"
REF="$REF" julia --project="$BENCH_ROOT/benchmarking" -e '
    using Pkg, TOML
    ref = TOML.parsefile(ENV["REF"])["deps"]
    names = ["GPUCompiler", "LLVM", "GPUToolbox", "GPUArrays", "KernelAbstractions", "CUDA", "CUDACore", "NCCL"]
    specs = [PackageSpec(name=n, version=ref[n][1]["version"]) for n in names if haskey(ref, n)]
    foreach(s -> println("   ", s.name, " => ", s.version), specs)
    Pkg.add(specs)' || { echo "ERROR adding NCCL: send the error before changing anything."; exit 1; }

echo "== 4. Check: packages load and Oceananigans' NCCL extension is available"
julia --project="$BENCH_ROOT/benchmarking" -e '
    using Pkg; Pkg.status(["Oceananigans", "CUDA", "MPI", "NCCL"])
    using Oceananigans, CUDA, NCCL
    ok = Base.get_extension(Oceananigans, :OceananigansNCCLExt) !== nothing
    println(ok ? "OK: suite ready on $(gethostname()), NCCL extension loaded" : "FAIL: NCCL extension did not load")
    ok || exit(1)'
echo "Done. BENCH_DIR for jobs/benchmark.sh: $BENCH_ROOT/benchmarking"

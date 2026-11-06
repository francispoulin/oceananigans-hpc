#!/bin/bash
# One-time setup on a LOGIN node (it needs internet access). From the repository root:
#
#     bash setup/setup.sh
#
# Steps:
#   1. install the packages (exact tested versions if Manifest.toml is present)
#   2. make MPI.jl use the system OpenMPI (MPIPreferences)
#   3. redirect OpenMPI_jll, which NetCDF/HDF5 load, to the same system OpenMPI library
#   4. precompile
#   5. load the main packages; 6. where this machine has a GPU, check that CUDA works on it
# It writes LocalPreferences.toml (machine-specific, so not under version control).

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,/^[^#]/{/^#SBATCH/d;/^# *shellcheck/d;s/^# \{0,1\}//p;}' "$0"; exit 0; }   # -h: usage
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source env/ocean_setup.sh

export OPENBLAS_NUM_THREADS=1

set -eo pipefail          # after loading modules, as module commands can return harmless errors

# The system OpenMPI library (OCEAN_MPI_ROOT is set by the env file). Alliance modules don't
# set LD_LIBRARY_PATH, so Julia can't find libmpi by searching; we pass its folder explicitly.
MPILIB_DIR="$OCEAN_MPI_ROOT/lib"
LIBMPI="$MPILIB_DIR/libmpi.so"
if [[ -z "$OCEAN_MPI_ROOT" || ! -f "$LIBMPI" ]]; then
    echo "ERROR: cannot find the system libmpi ('$LIBMPI'). Is the openmpi module loaded?"
    exit 1
fi

echo "== 1. Packages"
if [[ -f Manifest.toml ]]; then
    julia --project=. -e 'using Pkg; Pkg.instantiate()'
else
    julia --project=. -e 'using Pkg; Pkg.add(["Oceananigans", "CUDA", "MPI", "MPIPreferences",
                                              "OpenMPI_jll", "Preferences", "NCDatasets", "JLD2"])'
fi

echo "== 2. MPI.jl -> system OpenMPI ($MPILIB_DIR)"
julia --project=. -e "using MPIPreferences
                      MPIPreferences.use_system_binary(; extra_paths=[\"$MPILIB_DIR\"])"

echo "== 3. OpenMPI_jll -> system OpenMPI library"
julia --project=. -e "using Preferences, OpenMPI_jll
                      set_preferences!(OpenMPI_jll, \"libmpi_path\" => \"$LIBMPI\"; force=true)"
# The preference takes effect in a new Julia session:
julia --project=. -e 'using OpenMPI_jll; println("   OpenMPI_jll.libmpi_path = ", OpenMPI_jll.libmpi_path)'

echo "== 4. Precompile"
julia --project=. -e 'using Pkg; Pkg.precompile()'

echo
echo "Setup done. The libmpi_path above must be the system OpenMPI ($OCEAN_MPI_ROOT), not in your Julia depot."
echo "Next: sbatch jobs/hello_cpu.sh, then jobs/hello_gpu.sh, then jobs/checks.sh"

echo "== 5. Check that the main packages load"
julia --project=. -e 'using Oceananigans, CUDA, MPI, NCDatasets; println("   imports OK")'

echo "== 6. GPU"
# Loading CUDA is not enough: with a too-old NVIDIA driver it loads but cannot run (rondeau, Nov 6:
# driver 550 refuses the CUDA 13 forward-compatible driver). Login nodes on the Alliance have no
# GPU; the tests check the GPU there.
if nvidia-smi -L >/dev/null 2>&1; then
    julia --project=. -e 'using CUDA
        CUDA.functional() || (println("   CUDA does not work on this GPU: run with JULIA_DEBUG=CUDA_Driver_jll for why (often the NVIDIA driver is too old for the CUDA runtime)"); exit(1))
        println("   CUDA works: runtime ", CUDA.runtime_version(), ", driver ", CUDA.driver_version(), ", ", CUDA.name(CUDA.device()))'
else
    echo "   no GPU on this node (login node): checked by the tests instead"
fi

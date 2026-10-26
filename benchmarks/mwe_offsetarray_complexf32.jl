# Minimal reproducer, without Oceananigans: a batched tridiagonal solve in z (Thomas algorithm, one
# GPU thread per (i, j) column), as in Oceananigans' BatchedTridiagonalSolver. On Julia 1.13.2 it is
# about 3 times slower when the solution is an OffsetArray of Complex{Float32} than when it is a plain
# CuArray; on Julia 1.10.10 both are equally fast. Real numbers and Float64 are not affected.
# (Oct 26, 2026, A100: see benchmarks/tridiagonal_kernel.jl --solution=offsetarray.) Temporary: to be
# removed from the repository once reported upstream. Runs in its own temporary environment:
#
#     julia --startup-file=no benchmarks/mwe_offsetarray_complexf32.jl
#
using Pkg
Pkg.activate(temp = true; io = devnull)
Pkg.add(["CUDA", "KernelAbstractions", "OffsetArrays"]; io = devnull)
using CUDA, KernelAbstractions, OffsetArrays

@kernel function tridiagonal_z!(ϕ, a, b, f, t, Nz)
    i, j = @index(Global, NTuple)
    @inbounds begin
        β = b[i, j, 1]
        ϕ[i, j, 1] = f[i, j, 1] / β
        for k in 2:Nz
            t[i, j, k] = a[k-1] / β
            β = b[i, j, k] - a[k-1] * t[i, j, k]
            ϕ[i, j, k] = (f[i, j, k] - a[k-1] * ϕ[i, j, k-1]) / β
        end
        for k in Nz-1:-1:1
            ϕ[i, j, k] -= t[i, j, k+1] * ϕ[i, j, k+1]
        end
    end
end

Nx, Ny, Nz = 1024, 256, 1024
a = CUDA.ones(Float32, Nz - 1)
b = CUDA.fill(-4f0, Nx, Ny, Nz)
t = CUDA.zeros(Float32, Nx, Ny, Nz)
kernel! = tridiagonal_z!(CUDABackend(), (16, 16), (Nx, Ny))

println("julia ", VERSION, ", CUDA.jl ", pkgversion(CUDA), ", KernelAbstractions ", pkgversion(KernelAbstractions),
        ", OffsetArrays ", pkgversion(OffsetArrays), ", ", CUDA.name(CUDA.device()))
for T in (ComplexF32, Float32, ComplexF64)
    f = CUDA.rand(T, Nx, Ny, Nz)
    for (name, ϕ) in (("CuArray", similar(f)), ("OffsetArray", OffsetArray(similar(f), 0, 0, 0)))
        kernel!(ϕ, a, b, f, t, Nz); CUDA.synchronize()                    # compile
        ms = minimum(1e3 * CUDA.@elapsed(kernel!(ϕ, a, b, f, t, Nz)) for _ in 1:10)
        println(rpad("$T, ϕ::$name", 30), round(ms, digits = 2), " ms")
    end
end

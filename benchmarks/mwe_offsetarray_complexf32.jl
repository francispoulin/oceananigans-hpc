# Minimal reproducer, without Oceananigans: a batched tridiagonal solve in z (Thomas algorithm, one
# GPU thread per (i, j) column), as in Oceananigans' BatchedTridiagonalSolver. Inside Oceananigans, on
# Julia 1.13.2, it is about 3 times slower when the solution is an OffsetArray of Complex{Float32} than
# when it is a plain CuArray; on Julia 1.10.10 both are equally fast; real numbers and Float64 are not
# affected. Two loops: a plain Thomas algorithm (Oct 26: no slowdown on either Julia) and a copy of
# Oceananigans' loop (masked multiplications, old value kept where the pivot is tiny).
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

# The loop of Oceananigans 0.116.1 (src/Solvers/batched_tridiagonal_solver.jl, z direction), copied:
# masked multiplications, and the old value kept where the pivot is too small.
@inline masked_multiply(x, y) = x * y * (x != 0)
@inline float_eltype(::AbstractArray{T}) where T <: AbstractFloat = T
@inline float_eltype(::AbstractArray{<:Complex{T}}) where T <: AbstractFloat = T

# mul = masked_multiply (Oceananigans) or * (no masking); check = Val(true): keep the old value where
# the pivot is tiny, by reading it (Oceananigans); Val(:store): the same by storing only where it is not;
# Val(false): no check. Each is compiled separately (constants).
@kernel function oceananigans_tridiagonal_z!(ϕ, a, b, c, f, t, Nz, mul, check)
    i, j = @index(Global, NTuple)
    @inbounds begin
        β  = b[i, j, 1]
        ϕ[i, j, 1] = f[i, j, 1] / β
        for k = 2:Nz
            cᵏ⁻¹ = c[k-1]
            bᵏ   = b[i, j, k]
            aᵏ⁻¹ = a[k-1]
            t[i, j, k] = cᵏ⁻¹ / β
            β = bᵏ - mul(aᵏ⁻¹, t[i, j, k])
            fᵏ = f[i, j, k]
            definitely_diagonally_dominant = abs(β) > 10 * eps(float_eltype(ϕ))
            ϕ★ = (fᵏ - mul(aᵏ⁻¹, ϕ[i, j, k-1])) / β
            if check isa Val{true}       # Oceananigans: read the old value, store one or the other
                ϕ[i, j, k] = ifelse(definitely_diagonally_dominant, ϕ★, ϕ[i, j, k])
            elseif check isa Val{:store} # same result without reading the old value: store only if dominant
                definitely_diagonally_dominant && (ϕ[i, j, k] = ϕ★)
            else                         # no check
                ϕ[i, j, k] = ϕ★
            end
        end
        for k = Nz-1:-1:1
            ϕ[i, j, k] -= mul(t[i, j, k+1], ϕ[i, j, k+1])
        end
    end
end

Nx, Ny, Nz = 1024, 256, 1024
a = CUDA.ones(Float32, Nz - 1)
b = CUDA.fill(-4f0, Nx, Ny, Nz)
t = CUDA.zeros(Float32, Nx, Ny, Nz)
simple!      = tridiagonal_z!(CUDABackend(), (16, 16), (Nx, Ny))
oceananigans! = oceananigans_tridiagonal_z!(CUDABackend(), (16, 16), (Nx, Ny))

println("julia ", VERSION, ", CUDA.jl ", pkgversion(CUDA), ", KernelAbstractions ", pkgversion(KernelAbstractions),
        ", OffsetArrays ", pkgversion(OffsetArrays), ", ", CUDA.name(CUDA.device()))
timed_ms(k!, args...) = (k!(args...); CUDA.synchronize();                       # compile, then time
                         round(minimum(1e3 * CUDA.@elapsed(k!(args...)) for _ in 1:10), digits = 2))

println(rpad("", 28), " simple  Oceananigans  no-mask  no-check  if-store")
for T in (ComplexF32, Float32, ComplexF64)
    f = CUDA.rand(T, Nx, Ny, Nz)
    for (name, ϕ) in (("CuArray", similar(f)), ("OffsetArray", OffsetArray(similar(f), 0, 0, 0)))
        ms = (timed_ms(simple!, ϕ, a, b, f, t, Nz),
              timed_ms(oceananigans!, ϕ, a, b, a, f, t, Nz, masked_multiply, Val(true)),    # Oceananigans' loop
              timed_ms(oceananigans!, ϕ, a, b, a, f, t, Nz, *, Val(true)),                  # without masking
              timed_ms(oceananigans!, ϕ, a, b, a, f, t, Nz, masked_multiply, Val(false)),   # without the check
              timed_ms(oceananigans!, ϕ, a, b, a, f, t, Nz, masked_multiply, Val(:store)))  # check by a conditional store
        println(rpad("$T, ϕ::$name", 28), join(lpad.(ms, (7, 13, 9, 10, 10))), "  ms")
    end
end

# Experiment (temporary, for tools/compare_speed.sh --b-script): benchmarks/poisson_solver.jl with one
# change to Oceananigans' batched tridiagonal solve in z. The forward sweep keeps the old value where
# the pivot is too small by storing only where it is not, instead of
# `ϕ[i, j, k] = ifelse(dominant, ϕ★, ϕ[i, j, k])`, which reads the old value. Same results. On Julia 1.13.2
# the read makes the kernel 3.6 times slower for an OffsetArray of Complex{Float32}, the distributed
# Fourier-tridiagonal solver's case (Oct 26: benchmarks/mwe_offsetarray_complexf32.jl, A100:
# 36.4 -> 10.2 ms). From Oceananigans 0.116.1's src/Solvers/batched_tridiagonal_solver.jl:
#
#     bash tools/compare_speed.sh --a <candidate> --b <candidate> --b-script benchmarks/poisson_solver_if_store.jl
#
using Oceananigans

Core.eval(Oceananigans.Solvers, quote
    @inline function solve_batched_tridiagonal_system_z!(i, j, Nz, ϕ, a, b, c, f, t, grid, p, args, tridiagonal_direction)
        @inbounds begin
            β  = get_coefficient(i, j, 1, grid, b, p, tridiagonal_direction, args...)
            f₁ = get_coefficient(i, j, 1, grid, f, p, tridiagonal_direction, args...)
            ϕ[i, j, 1] = f₁ / β

            for k = 2:Nz
                cᵏ⁻¹ = get_coefficient(i, j, k-1, grid, c, p, tridiagonal_direction, args...)
                bᵏ   = get_coefficient(i, j, k,   grid, b, p, tridiagonal_direction, args...)
                aᵏ⁻¹ = get_coefficient(i, j, k-1, grid, a, p, tridiagonal_direction, args...)

                t[i, j, k] = cᵏ⁻¹ / β
                β = bᵏ - masked_multiply(aᵏ⁻¹, t[i, j, k])
                fᵏ = get_coefficient(i, j, k, grid, f, p, tridiagonal_direction, args...)

                definitely_diagonally_dominant = abs(β) > 10 * eps(float_eltype(ϕ))
                ϕ★ = (fᵏ - masked_multiply(aᵏ⁻¹, ϕ[i, j, k-1])) / β
                definitely_diagonally_dominant && (ϕ[i, j, k] = ϕ★)   # was: ifelse(..., ϕ★, ϕ[i, j, k])
            end

            for k = Nz-1:-1:1
                ϕ[i, j, k] -= masked_multiply(t[i, j, k+1], ϕ[i, j, k+1])
            end
        end
    end
end)

include(joinpath(@__DIR__, "poisson_solver.jl"))

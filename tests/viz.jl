# Test: the viz environment works: write a small NetCDF file, read it back, make a figure (PNG)
# and a short movie (MP4) with CairoMakie, as the movie and growth scripts do, and take the FFT
# of a sine with FFTA, as spectra scripts do. CPU only.
# Run with:  julia --project=$OCEAN_HPC_ROOT/viz tests/viz.jl

using NCDatasets, CairoMakie, FFTA, Printf

dir = mktempdir()
file = joinpath(dir, "test.nc")
x, y, t = range(0, 1, 64), range(0, 1, 48), 0:0.1:1
NCDataset(file, "c") do ds
    defDim(ds, "x", length(x)); defDim(ds, "y", length(y)); defDim(ds, "time", length(t))
    defVar(ds, "x", collect(x), ("x",)); defVar(ds, "y", collect(y), ("y",)); defVar(ds, "time", collect(t), ("time",))
    v = defVar(ds, "b", Float64, ("x", "y", "time"))
    for (k, tk) in enumerate(t)
        v[:, :, k] = [sin(2π * (xi - tk)) * cos(2π * yj) for xi in x, yj in y]
    end
end

b, times = NCDataset(file) do ds
    Array(ds["b"]), Array(ds["time"])
end
read_ok = size(b) == (64, 48, length(t))

png = joinpath(dir, "test.png")
fig = Figure(size = (400, 300))
ax = Axis(fig[1, 1], title = "b at t = 0")
heatmap!(ax, collect(x), collect(y), b[:, :, 1])
save(png, fig)

mp4 = joinpath(dir, "test.mp4")
n = Observable(1)
fig2 = Figure(size = (400, 300))
ax2 = Axis(fig2[1, 1], title = @lift(@sprintf("t = %.1f", times[$n])))
heatmap!(ax2, collect(x), collect(y), @lift(b[:, :, $n]))
record(fig2, mp4, 1:length(times); framerate = 5) do k
    n[] = k
end

# FFT: the rfft of a sine with 5 periods on a periodic grid peaks at wavenumber 5 with amplitude N/2,
# and irfft gives the sine back
N, k0 = 128, 5
s = [sin(2π * k0 * (i - 1) / N) for i in 1:N]
spectrum = abs.(rfft(s))
fft_ok = argmax(spectrum) - 1 == k0 && isapprox(spectrum[k0 + 1], N / 2) && irfft(rfft(s), N) ≈ s

png_ok = isfile(png) && filesize(png) > 1000
mp4_ok = isfile(mp4) && filesize(mp4) > 1000
println("NetCDF read back: ", read_ok, ", PNG: ", png_ok, " (", filesize(png), " bytes), MP4: ", mp4_ok,
        " (", isfile(mp4) ? filesize(mp4) : 0, " bytes), FFT: ", fft_ok)
ok = read_ok && png_ok && mp4_ok && fft_ok
println(ok ? "PASS: viz (NetCDF, PNG, MP4, FFT)" : "FAIL: viz")
ok || exit(1)

#!/usr/bin/env julia
# usage: julia --project generate_many.jl [outdir] [n]
#
# Writes `n` separate 256^3 Int16 images (32 MiB each), the shape of a cohort
# of per-subject anatomicals. Default n = 100, so ~3.2 GiB total.
#
# The phantom is built once and given a per-subject offset, so the files differ
# without costing a fresh phantom each time.

using NIfTI

const DIMS = (256, 256, 256)

function phantom(nx, ny, nz)
    p = Array{Float32}(undef, nx, ny, nz)
    cx, cy, cz = (nx + 1) / 2, (ny + 1) / 2, (nz + 1) / 2
    @inbounds for k in 1:nz, j in 1:ny, i in 1:nx
        r = ((i - cx) / (0.42nx))^2 + ((j - cy) / (0.42ny))^2 + ((k - cz) / (0.42nz))^2
        v = r > 1 ? 0.0f0 : r > 0.75 ? 300.0f0 : r > 0.35 ? 900.0f0 : 600.0f0
        p[i, j, k] = v + 40.0f0 * Float32(sin(i / 9) * cos(j / 11) * sin(k / 7))
    end
    return p
end

function main(args)
    dir = isempty(args) ? joinpath(@__DIR__, "data", "cohort") : args[1]
    n = length(args) >= 2 ? parse(Int, args[2]) : 100
    mkpath(dir)

    base = round.(Int16, phantom(DIMS...))
    data = similar(base)
    t = @elapsed for s in 1:n
        data .= base .+ Int16(s)
        niwrite(joinpath(dir, "sub-" * lpad(s, 3, '0') * "_T1w.nii"),
                NIVolume(data; voxel_size = (1.0f0, 1.0f0, 1.0f0)))
    end
    niwrite(joinpath(dir, "tiny.nii"), NIVolume(rand(Int16, 4, 4, 2)))

    total = sum(filesize, joinpath.(dir, filter(endswith(".nii"), readdir(dir))))
    println(n, " images, ", round(total / 2^30; digits = 2), " GiB, ",
            round(t; digits = 1), " s -> ", dir)
    return 0
end

exit(main(ARGS))

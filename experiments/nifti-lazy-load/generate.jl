#!/usr/bin/env julia
# usage: julia --project generate.jl [outdir]
#
# Writes the synthetic corpus the lazy-load probe measures against:
#
#   fmri.nii       128x128x72x400 Float32, ~1.8 GiB, uncompressed
#   fmri.nii.gz    the same volume, gzipped
#   anat.nii       256x256x256 Int16, little-endian (native)
#   anat_be.nii    the same volume rewritten big-endian
#   tiny_*.nii     warmup files, one per (eltype, ndims) the probe touches
#
# The data is a smooth phantom rather than noise so the gzipped copy is a
# realistic size instead of incompressible.

using NIfTI, Random

const FMRI_DIMS = (128, 128, 72, 400)
const ANAT_DIMS = (256, 256, 256)

"""Ellipsoid phantom with three tissue values, plus a low-frequency ripple."""
function phantom(nx, ny, nz)
    p = Array{Float32}(undef, nx, ny, nz)
    cx, cy, cz = (nx + 1) / 2, (ny + 1) / 2, (nz + 1) / 2
    @inbounds for k in 1:nz, j in 1:ny, i in 1:nx
        r = ((i - cx) / (0.42nx))^2 + ((j - cy) / (0.42ny))^2 + ((k - cz) / (0.42nz))^2
        v = r > 1 ? 0.0f0 :            # background
            r > 0.75 ? 300.0f0 :       # skull / csf
            r > 0.35 ? 900.0f0 : 600.0f0
        p[i, j, k] = v + 40.0f0 * Float32(sin(i / 9) * cos(j / 11) * sin(k / 7))
    end
    return p
end

function write_fmri(path, dims; seed = 1234)
    nx, ny, nz, nt = dims
    rng = MersenneTwister(seed)
    base = phantom(nx, ny, nz)
    data = Array{Float32}(undef, dims)
    @inbounds for t in 1:nt
        drift = 1.0f0 + 0.02f0 * Float32(sin(t / 17))
        vt = @view data[:, :, :, t]
        vt .= base .* drift
        vt .+= 5.0f0 .* Float32.(randn(rng, Float32, nx, ny, nz))
    end
    niwrite(path, NIVolume(data; voxel_size = (2.0f0, 2.0f0, 2.0f0), time_step = 2.0f0))
    return path
end

function write_anat(path, dims)
    data = round.(Int16, phantom(dims...))
    niwrite(path, NIVolume(data; voxel_size = (1.0f0, 1.0f0, 1.0f0)))
    return path
end

"""
Rewrite `src` as a big-endian file at `dst`.

The header round-trips through NIfTI.jl's own reader and writer, so the field
layout is whatever the package itself believes it to be; only the byte order
of the header fields and of the voxel data is flipped.
"""
function write_bigendian(src, dst)
    vol = niread(src)
    hdr = NIfTI.byteswap(deepcopy(vol.header))   # native -> big-endian
    open(dst, "w") do io
        write(io, hdr)
        write(io, Int32(0))                      # empty extension terminator
        write(io, hton.(vol.raw))
    end
    return dst
end

"""Warmup files: same eltype and rank as the real ones, a few voxels each."""
function write_tiny(dir)
    niwrite(joinpath(dir, "tiny_fmri.nii"), NIVolume(rand(Float32, 4, 4, 2, 3)))
    niwrite(joinpath(dir, "tiny_fmri.nii.gz"), NIVolume(rand(Float32, 4, 4, 2, 3)))
    niwrite(joinpath(dir, "tiny_anat.nii"), NIVolume(rand(Int16, 4, 4, 2)))
    write_bigendian(joinpath(dir, "tiny_anat.nii"), joinpath(dir, "tiny_anat_be.nii"))
    return nothing
end

function main(args)
    dir = isempty(args) ? joinpath(@__DIR__, "data") : args[1]
    mkpath(dir)

    for (name, f) in (("fmri.nii", p -> write_fmri(p, FMRI_DIMS)),
                      ("anat.nii", p -> write_anat(p, ANAT_DIMS)))
        path = joinpath(dir, name)
        print(rpad(name, 16)); flush(stdout)
        t = @elapsed f(path)
        println(round(filesize(path) / 2^20; digits = 1), " MiB  ",
                round(t; digits = 1), " s")
    end

    print(rpad("fmri.nii.gz", 16)); flush(stdout)
    t = @elapsed niwrite(joinpath(dir, "fmri.nii.gz"), niread(joinpath(dir, "fmri.nii")))
    println(round(filesize(joinpath(dir, "fmri.nii.gz")) / 2^20; digits = 1), " MiB  ",
            round(t; digits = 1), " s")

    print(rpad("anat_be.nii", 16)); flush(stdout)
    t = @elapsed write_bigendian(joinpath(dir, "anat.nii"), joinpath(dir, "anat_be.nii"))
    println(round(filesize(joinpath(dir, "anat_be.nii")) / 2^20; digits = 1), " MiB  ",
            round(t; digits = 1), " s")

    write_tiny(dir)
    println("tiny warmup files written to ", dir)
    return 0
end

exit(main(ARGS))

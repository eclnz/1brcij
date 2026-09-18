#!/usr/bin/env julia
# usage: julia --project run.jl [datadir]
#
# Drives probe.jl once per scenario, each in its own process with a cold page
# cache, and prints the comparison table.

const ORDER = [
    "eager_open", "eager_voxels", "eager_sumall",
    "mmap_open", "mmap_voxels", "mmap_timeseries",
    "mmap_oneslice", "mmap_onevolume", "mmap_sumall",
    "mmap_voxels_rand", "mmap_tseries_rand",
    "gz_eager_voxels", "gz_mmap_open",
    "le_mmap_voxels", "be_mmap_voxels", "be_eager_voxels",
]

mib(x) = string(round(x / 2^20; digits = 2))

function main(args)
    dir = isempty(args) ? joinpath(@__DIR__, "data") : args[1]
    isdir(dir) || (println(stderr, "no data dir: ", dir, " -- run generate.jl first"); return 2)
    probe = joinpath(@__DIR__, "probe.jl")

    rows = Vector{String}[]
    for name in ORDER
        print(stderr, "running ", name, " ... ")
        out = try
            readchomp(pipeline(`$(Base.julia_cmd()) --project=$(Base.active_project()) $probe $name $dir`,
                               stderr = stderr))
        catch err
            println(stderr, "FAILED")
            continue
        end
        println(stderr, "ok")
        f = split(out, '\t')
        push!(rows, [f[1], mib(parse(Int, f[3])), f[4],
                     mib(parse(Int, f[5])), mib(parse(Int, f[6])),
                     mib(parse(Int, f[7])), f[8]])
    end

    hdr = ["scenario", "file MiB", "wall s", "read() MiB", "disk MiB", "ΔRSS MiB", "majflt"]
    widths = [maximum(length, [hdr[i]; [r[i] for r in rows]]) for i in eachindex(hdr)]
    println(join((rpad(hdr[i], widths[i]) for i in eachindex(hdr)), "  "))
    println(join(("-"^widths[i] for i in eachindex(hdr)), "  "))
    for r in rows
        println(join((i == 1 ? rpad(r[i], widths[i]) : lpad(r[i], widths[i]) for i in eachindex(r)), "  "))
    end
    return 0
end

exit(main(ARGS))

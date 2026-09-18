#!/usr/bin/env julia
# usage: julia --project run_many.jl [cohortdir]
#
# Drives probe_many.jl once per scenario, each in its own process with a cold
# page cache. Needs root for the cache drop; see README.

const ORDER = ["many_eager", "many_mmap", "many_mmap_rand", "many_mmap_held", "many_mmap_gc"]

mib(x) = string(round(x / 2^20; digits = 2))

function main(args)
    dir = isempty(args) ? joinpath(@__DIR__, "data", "cohort") : args[1]
    isdir(dir) || (println(stderr, "no cohort dir: ", dir, " -- run generate_many.jl first"); return 2)
    probe = joinpath(@__DIR__, "probe_many.jl")

    rows = Vector{String}[]
    for name in ORDER
        print(stderr, "running ", name, " ... ")
        out = try
            readchomp(pipeline(`$(Base.julia_cmd()) --project=$(Base.active_project()) $probe $name $dir`,
                               stderr = stderr))
        catch
            println(stderr, "FAILED"); continue
        end
        println(stderr, "ok")
        f = split(out, '\t')
        push!(rows, [f[1], f[2], mib(parse(Int, f[3])), f[4],
                     mib(parse(Int, f[5])), mib(parse(Int, f[6])),
                     mib(parse(Int, f[7])), f[8], f[9]])
    end

    hdr = ["scenario", "n", "total MiB", "wall s", "read() MiB", "disk MiB", "ΔRSS MiB", "majflt", "Δfds"]
    w = [maximum(length, [hdr[i]; [r[i] for r in rows]]) for i in eachindex(hdr)]
    println(join((rpad(hdr[i], w[i]) for i in eachindex(hdr)), "  "))
    println(join(("-"^w[i] for i in eachindex(hdr)), "  "))
    for r in rows
        println(join((i == 1 ? rpad(r[i], w[i]) : lpad(r[i], w[i]) for i in eachindex(r)), "  "))
    end
    return 0
end

exit(main(ARGS))

#!/usr/bin/env julia
# usage: julia bin/generate.jl <row count> [output path] [seed]
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))

function main(args)
    if isempty(args)
        println(stderr, "usage: generate.jl <row count> [output path] [seed]")
        return 2
    end
    n = parse(Int, replace(args[1], "_" => ""))
    path = length(args) >= 2 ? args[2] : "measurements.txt"
    seed = length(args) >= 3 ? parse(Int, args[3]) : 20240101
    t0 = time_ns()
    OneBRC.generate(path, n; seed = seed)
    println(stderr, "wrote $n rows to $path ($(round(filesize(path) / 2^30; digits = 2)) GiB) ",
            "in $(round((time_ns() - t0) / 1e9; digits = 1)) s")
    return 0
end

exit(main(ARGS))

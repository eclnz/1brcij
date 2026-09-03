#!/usr/bin/env julia
# usage: julia -t auto -O3 --check-bounds=no scripts/bench.jl <file> [repeats]
#
# Steady-state timing, compilation excluded.
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
using .OneBRC

function main(args)
    isempty(args) && (println(stderr, "usage: bench.jl <file> [repeats]"); return 2)
    path = args[1]
    reps = length(args) >= 2 ? parse(Int, args[2]) : 5
    bytes = filesize(path)

    stats = OneBRC.run_file(path)                    # compile
    rows = sum(s.cnt for s in values(stats); init = 0)

    times = Float64[]
    for _ in 1:reps
        GC.gc()
        t = time_ns()
        OneBRC.run_file(path)
        push!(times, (time_ns() - t) / 1e9)
    end
    sort!(times)
    best, med = times[1], times[(end + 1) ÷ 2]
    println("file      ", path)
    println("size      ", round(bytes / 2^30; digits = 3), " GiB, ", rows, " rows, ",
            length(stats), " stations")
    println("threads   ", Threads.nthreads())
    println("best      ", round(best; digits = 3), " s  (",
            round(rows / best / 1e6; digits = 1), " M rows/s, ",
            round(bytes / best / 2^30; digits = 2), " GiB/s)")
    println("median    ", round(med; digits = 3), " s")
    println("all       ", join(round.(times; digits = 3), " "))
    return 0
end

exit(main(ARGS))

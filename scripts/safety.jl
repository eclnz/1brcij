#!/usr/bin/env julia
# What the unsafe machinery is worth.
#
#   julia -t auto -O3 --check-bounds=no scripts/safety.jl <file>   # unsafe, and safe unchecked
#   julia -t auto -O3 scripts/safety.jl <file>                     # safe, checked
#
# Run it both ways: --check-bounds=no is a startup flag, so a single process
# cannot measure checked and unchecked code side by side.
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
using .OneBRC, Printf

function main(path)
    rows = countlines(path)
    checked = Base.JLOptions().check_bounds != 2      # 2 == --check-bounds=no
    @assert OneBRC.format_result(OneBRC.run_file(path)) ==
            OneBRC.format_result(OneBRC.Safe.run_file(path))
    for (label, f) in (("unsafe", OneBRC.run_file), ("safe", OneBRC.Safe.run_file))
        f(path)
        best = Inf
        for _ in 1:7
            t = time_ns(); f(path); best = min(best, (time_ns() - t) / 1e9)
        end
        @printf("%-8s %-14s %7.3f s   %6.1f M rows/s\n", label,
                checked ? "bounds checked" : "checks off", best, rows / best / 1e6)
    end
end

main(ARGS[1])

#!/usr/bin/env julia
# What the pointer machinery is worth against ordinary Julia.
#
#   julia -t auto -O3 --check-bounds=no scripts/safety.jl <file>
#
# Run it without the flag too: src/safe.jl carries its own @inbounds, so the two
# should agree, which is the check that the annotations cover the hot path.
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
using .OneBRC, Printf

function main(path)
    rows = countlines(path)
    checked = Base.JLOptions().check_bounds != 2      # 2 == --check-bounds=no
    @assert OneBRC.format_result(OneBRC.run_file(path)) ==
            OneBRC.format_result(OneBRC.Safe.run_file(path))
    for (label, f) in (("pointers", OneBRC.run_file), ("ordinary", OneBRC.Safe.run_file))
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

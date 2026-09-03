#!/usr/bin/env julia
# Standalone entry point: no package environment needed, just
#   julia -t auto -O3 --check-bounds=no --startup-file=no bin/brc.jl measurements.txt
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
exit(OneBRC.main(ARGS))

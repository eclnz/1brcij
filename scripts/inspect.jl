#!/usr/bin/env julia
# The §11 profiling checklist, as something runnable.
#
#   julia -t auto -O3 --check-bounds=no --startup-file=no scripts/inspect.jl
#
# Checks, in order of how much they matter:
#   * no `Any`/`Union`/`Core.Box` in the hot path (boxing means allocation, and
#     allocation in a billion-iteration loop means the GC is the bottleneck);
#   * the hot path allocates exactly zero bytes;
#   * `trailing_zeros` lowered to `tzcnt`, and the bounds checks are gone.
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
using .OneBRC
using InteractiveUtils

const SAMPLE = let rows = String[]
    for i in 1:20_000
        push!(rows, "Station$(i % 413);$(((i * 37) % 1999 - 999) / 10)")
    end
    data = Vector{UInt8}(codeunits(join(rows, "\n") * "\n"))
    append!(data, zeros(UInt8, 64))
    data
end
const NBYTES = something(findlast(==(UInt8('\n')), SAMPLE))

function typed_output(f, types)
    io = IOBuffer()
    code_warntype(io, f, types)
    return String(take!(io))
end

function main()
    ok = true

    println("== type stability")
    for (f, types) in ((OneBRC.parse_value, (UInt64,)),
                       (OneBRC.scan_name, (Ptr{UInt8}, Int)),
                       (OneBRC.process_row!, (OneBRC.Table, Ptr{UInt8}, Int)),
                       (OneBRC.process_segment!, (OneBRC.Table, Ptr{UInt8}, Int, Int)),
                       (OneBRC.update!, (OneBRC.Table, Ptr{UInt8}, UInt64, Int, Int, Int64)))
        s = typed_output(f, types)
        # `::Union{}` is the bottom type — an unreachable value, not an
        # instability — so only a Union with members is a red flag.
        bad = count(w -> occursin(w, s), ("::Any", "Core.Box")) +
              count(r"::Union\{[^}]", s)
        println(rpad(string(nameof(f)), 18), bad == 0 ? "clean" : "SUSPECT")
        ok &= bad == 0
    end

    println("\n== allocation in the hot path")
    tbl = OneBRC.Table()
    GC.@preserve SAMPLE begin
        p = pointer(SAMPLE)
        OneBRC.process_segment!(tbl, p, 0, NBYTES)          # compile
        n = @allocated OneBRC.process_segment!(OneBRC.Table(), p, 0, NBYTES)
        # the fresh Table itself is the only allowed allocation
        base = @allocated OneBRC.Table()
        println("process_segment! over $(NBYTES) bytes: $(n - base) bytes")
        ok &= (n - base) == 0
    end

    println("\n== native code for parse_value")
    io = IOBuffer()
    code_native(io, OneBRC.parse_value, (UInt64,); syntax = :intel, debuginfo = :none)
    asm = String(take!(io))
    for want in ("tzcnt", "imul")
        found = occursin(want, asm)
        println(rpad(want, 18), found ? "present" : "MISSING")
        ok &= found
    end
    println("instructions      ", count(==('\n'), asm))

    println("\n", ok ? "all checks passed" : "SOME CHECKS FAILED")
    return ok ? 0 : 1
end

exit(main())

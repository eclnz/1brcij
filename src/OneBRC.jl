"""
    OneBRC

Min/mean/max per weather station from a ~13.8 GB `<station>;<temperature>` file.

    julia -t auto -O3 --check-bounds=no --startup-file=no bin/brc.jl measurements.txt

Load-bearing assumptions, all from the challenge spec: little-endian; values of
the form `-?d?d.d`; names under 100 bytes with no `';'` or newline; well-formed,
newline-terminated rows.

The hot path is ordinary Julia — `Vector{UInt8}` indexing under `@inbounds`,
not raw pointers. Two places step outside it, each documented where it appears:
`match16` (an LLVM intrinsic Julia cannot otherwise spell) and one `unsafe_load`
in `finish_row!` (a load LLVM will not emit from safe code).

`@inbounds` is written out as well, since `--check-bounds=no` is a startup flag
and unavailable to a PackageCompiler app.
"""
module OneBRC

using Mmap
using Random

export run_file, format_result, baseline, generate

include("parse.jl")
include("table.jl")
include("scan.jl")
include("output.jl")
include("reference.jl")
include("generate.jl")

# The fast path overreads 8 bytes, which an mmap only tolerates because the
# kernel zero-fills the last partial page — and not at all when the file size is
# a multiple of it. So carve off a tail for the byte-at-a-time parser.
const TAIL_SLACK = 1 << 16
const MAX_ROW_BYTES = 1 << 12

"""
    fast_region_end(data, fsize) -> Int

Row boundary at least `TAIL_SLACK` before the end of the file, so wide loads
below it stay inside the mapping. Returns 0 if the window holds no boundary,
sending everything down the slow path — only reachable on malformed input.
"""
function fast_region_end(data::Vector{UInt8}, fsize::Int)
    fsize <= TAIL_SLACK && return 1
    from = fsize - TAIL_SLACK
    stop = min(from + MAX_ROW_BYTES, fsize)
    i = from
    @inbounds while i < stop
        data[i] == NEWLINE && return i + 1
        i += 1
    end
    return 1
end

"""Aggregate one measurements file. Statistics are in tenths of a degree."""
function run_file(path::AbstractString)
    io = open(path, "r")
    try
        fsize = Int(filesize(io))
        fsize == 0 && return Dict{String,Stat}()
        data = Mmap.mmap(io, Vector{UInt8}, fsize)
        fend = fast_region_end(data, fsize)
        stats = merge_tables(scan_parallel(data, fend), data)
        accumulate_slow!(stats, data, fend - 1, fsize)
        return stats
    finally
        close(io)
    end
end

const USAGE = """
usage: brc [options] <measurements file>

  --check         also run the reference implementation and diff the results
  --baseline      run only the reference implementation
  --clean-exit    shut down normally instead of _exit(2) (see below)
  --time          report elapsed wall time on stderr

By default the process ends with `_exit(2)` once the answer is flushed, skipping
teardown of a 13.8 GB mapping after the result is already known.
"""

function main(args::Vector{String})::Cint
    opts = Set(a for a in args if startswith(a, "--"))
    files = [a for a in args if !startswith(a, "--")]
    if length(files) != 1 || !isempty(setdiff(opts, Set(["--check", "--baseline",
                                                         "--clean-exit", "--time"])))
        print(stderr, USAGE)
        return 2
    end
    path = files[1]
    if !isfile(path)
        println(stderr, "brc: no such file: ", path)
        return 2
    end
    if Threads.nthreads() == 1
        println(stderr, "brc: running on a single thread; start julia with -t auto")
    end

    t0 = time_ns()
    stats = "--baseline" in opts ? baseline(path) : run_file(path)
    elapsed = (time_ns() - t0) / 1e9
    out = format_result(stats)

    if "--check" in opts
        ref = format_result(baseline(path))
        if ref != out
            println(stderr, "brc: MISMATCH against the reference implementation")
            return 1
        end
        println(stderr, "brc: matches the reference implementation")
    end

    println(out)
    "--time" in opts && println(stderr, "brc: ", round(elapsed; digits = 3), " s")
    flush(stdout)
    flush(stderr)
    if !("--clean-exit" in opts)
        ccall(:_exit, Cvoid, (Cint,), 0)   # skips atexit hooks, finalizers, munmap
    end
    return 0
end

"""Entry point for a PackageCompiler app; the signature is prescribed."""
function julia_main()::Cint
    try
        return main(ARGS)
    catch e
        showerror(stderr, e, catch_backtrace())
        return 1
    end
end

# 1BRC times the launch script end to end, so first-call compilation counts.
# Exercising the pipeline here bakes the specialisations into the package image,
# taking a run's fixed cost from 819 ms to 174 ms.
function _precompile_workload()
    rows = IOBuffer()
    for i in 1:400
        print(rows, "Station", i % 37, ';', i % 2 == 0 ? "-" : "",
              (i % 90) + 9, '.', i % 10, '\n')
    end
    data = take!(rows)
    stop = something(findlast(==(NEWLINE), data))
    append!(data, zeros(UInt8, 64))
    tbl = Table()
    process_segment!(tbl, data, 1, stop)
    scan_serial!(tbl, data, 1, stop)
    stats = merge_tables([tbl], data)
    accumulate_slow!(stats, data, 0, stop)
    fast_region_end(data, stop)
    format_result(stats)
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_workload()
    # Anything needing the filesystem is cached by directive instead.
    precompile(run_file, (String,))
    precompile(main, (Vector{String},))
    precompile(julia_main, ())
    precompile(baseline, (String,))
    precompile(scan_parallel, (Vector{UInt8}, Int))
end

end # module

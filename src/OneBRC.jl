"""
    OneBRC

The One Billion Row Challenge in Julia: aggregate min/mean/max per weather
station from a ~13.8 GB `<station>;<temperature>` text file.

Layered so each optimisation can be read, tested and benchmarked on its own:

| file            | layer                                                      |
|:----------------|:-----------------------------------------------------------|
| `reference.jl`  | the slow, obviously correct oracle                          |
| `parse.jl`      | SWAR delimiter scanning, name hashing, branchless parsing   |
| `table.jl`      | open-addressing table keyed by offsets into the mapping     |
| `scan.jl`       | mmap segmentation, atomic work queue, ILP scan cursors      |
| `output.jl`     | half-up rounding and the challenge's output format          |

Load-bearing assumptions about the input, all of them from the challenge spec:

  * little-endian machine — every SWAR trick reads byte 0 of memory as the
    least significant byte of a `UInt64`;
  * temperatures are always `-?d?d.d`, i.e. one fractional digit and at most
    two integer digits;
  * station names are shorter than 100 bytes and never contain `';'` or `'\\n'`;
  * rows are well formed and newline terminated.

Run it with:

    julia -t auto -O3 --check-bounds=no --startup-file=no bin/brc.jl measurements.txt

`@inbounds` is written explicitly in the hot paths as well, because
`--check-bounds=no` is a startup flag and is not available to an app compiled
with PackageCompiler.
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

# The fast path may read up to 8 bytes past any offset it touches.  Inside an
# mmap that is only safe because the kernel zero-fills the last partial page —
# and it is not safe at all when the file size is an exact multiple of the page
# size.  Rather than depend on that, carve a tail off the end of the file and
# hand it to the byte-at-a-time parser: a few thousand rows out of a billion.
const TAIL_SLACK = 1 << 16
const MAX_ROW_BYTES = 1 << 12

"""
    fast_region_end(data, fsize) -> Int

Row boundary at least `TAIL_SLACK` bytes before the end of the file, so that
wide loads from any offset below it stay well inside the mapping.  Returns 0
if no row boundary turns up in the search window, in which case the whole file
goes down the slow path (only reachable on malformed input).
"""
function fast_region_end(data::Vector{UInt8}, fsize::Int)
    fsize <= TAIL_SLACK && return 0
    from = fsize - TAIL_SLACK
    stop = min(from + MAX_ROW_BYTES, fsize)
    p = from
    @inbounds while p < stop
        data[p + 1] == NEWLINE && return p + 1
        p += 1
    end
    return 0
end

"""
    run_file(path) -> Dict{String,Stat}

Aggregate one measurements file.  Statistics are in tenths of a degree.
"""
function run_file(path::AbstractString)
    io = open(path, "r")
    try
        fsize = Int(filesize(io))
        fsize == 0 && return Dict{String,Stat}()
        data = Mmap.mmap(io, Vector{UInt8}, fsize)
        # `GC.@preserve` is not optional: without it the compiler may consider
        # `data` dead while raw pointers into it are still live.
        return GC.@preserve data begin
            base = pointer(data)
            fend = fast_region_end(data, fsize)
            stats = merge_tables(scan_parallel(base, fend), base)
            accumulate_slow!(stats, data, fend, fsize)
            stats
        end
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

By default the process ends with `_exit(2)` once the answer is flushed, which
skips tearing down a 13.8 GB mapping — tens to hundreds of milliseconds that
would otherwise be spent after the result is already known.
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

# ---------------------------------------------------------------------------
# Precompilation workload.
#
# 1BRC measures the launch script end to end, so compilation that happens on
# the first call is measured too — the same problem the JVM entries solved with
# GraalVM native images.  Exercising the pipeline here bakes the native code
# for these specialisations into the package image, so `using OneBRC` is all
# the run pays.  It must run *during* precompilation to be cached, hence the
# `jl_generating_output` guard.
# ---------------------------------------------------------------------------
function _precompile_workload()
    rows = IOBuffer()
    for i in 1:400
        print(rows, "Station", i % 37, ';', i % 2 == 0 ? "-" : "",
              (i % 90) + 9, '.', i % 10, '\n')
    end
    data = take!(rows)
    stop = something(findlast(==(NEWLINE), data))
    append!(data, zeros(UInt8, 64))
    stats = GC.@preserve data begin
        p = pointer(data)
        tbl = Table()
        process_segment!(tbl, p, 0, stop)
        scan_serial!(tbl, p, 0, stop)
        merge_tables([tbl], p)
    end
    accumulate_slow!(stats, data, 0, stop)
    fast_region_end(data, stop)
    format_result(stats)
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_workload()
    # Methods that cannot be exercised without touching the filesystem still
    # get their native code cached by an explicit directive.
    precompile(run_file, (String,))
    precompile(main, (Vector{String},))
    precompile(julia_main, ())
    precompile(baseline, (String,))
    precompile(scan_parallel, (Ptr{UInt8}, Int))
end

end # module

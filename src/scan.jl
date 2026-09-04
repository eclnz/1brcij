# Segmentation, work queue, and the per-thread scan.

using Base.Cartesian: @nexprs, @nall

const SEGMENT_SIZE = 1 << 21      # 2 MiB: balances without losing locality
const STREAMS = 5                 # swept 1..8; 4..6 tie, 7+ spills
@assert STREAMS == 5   # process_segment! unrolls this many cursors by hand
const MIN_STREAM_BYTES = 1 << 14  # below this a segment is scanned serially

"""Atomic segment counter — the only shared mutable state in the program."""
struct Work
    nseg::Int
    counter::Threads.Atomic{Int}
end

Work(nseg::Int) = Work(nseg, Threads.Atomic{Int}(1))

"""Claim the next segment, or 0 when the queue is drained."""
@inline function claim!(w::Work)
    i = Threads.atomic_add!(w.counter, 1)   # returns the old value
    return i <= w.nseg ? i : 0
end

"""Index just past the next newline at or after `i`, clamped to `limit`."""
@inline function next_row_start(data::Vector{UInt8}, i::Int, limit::Int)
    @inbounds while i < limit && data[i] != NEWLINE
        i += 1
    end
    return i < limit ? i + 1 : limit
end

"""
    segment_start(data, seg, fend) -> Int

Start of segment `seg` (1-based), repaired to a row boundary. A segment's stop
is this same function applied to `seg + 1`, so neighbouring threads agree by
construction and every row is scanned once.
"""
@inline function segment_start(data::Vector{UInt8}, seg::Int, fend::Int)
    seg == 1 && return 1
    i = (seg - 1) * SEGMENT_SIZE + 1
    i >= fend && return fend
    return next_row_start(data, i, fend)
end

"""Parse the value, accumulate, and return the index of the next row."""
@inline function finish_row!(t::Table, data::Vector{UInt8}, pos::Int, name::Name)
    vstart = name.stop + 1
    # The one place `load8` is not enough: `parse_value` splits the word into a
    # narrow and a wide use, and LLVM then reassociates the shift-and-or chain
    # rather than folding it into one `mov` — 8 `movzx` per row, ~15% end to end.
    v, adv = parse_value(GC.@preserve data unsafe_load(Ptr{UInt64}(pointer(data, vstart))))
    update!(t, data, pos, name, v)
    return vstart + adv
end

"""One `<name>;<value>` row; returns the index of the next."""
@inline function process_row!(t::Table, data::Vector{UInt8}, pos::Int)
    return finish_row!(t, data, pos, scan_name(data, pos))
end

@inline function scan_serial!(t::Table, data::Vector{UInt8}, pos::Int, stop::Int)
    while pos < stop
        pos = process_row!(t, data, pos)
    end
    return nothing
end

"""
    process_segment!(t, data, a, b)

Scan `[a, b)`, which must begin on a row boundary.

Row *n+1*'s position is unknown until row *n* is parsed, so one cursor is a
single dependency chain where every cache miss stalls everything behind it.
`STREAMS` sub-ranges advanced round-robin give the out-of-order engine
independent chains to overlap, each still read sequentially.

Hashing every stream before parsing any of them also puts four rows of work
between a probe's address becoming known and the probe itself, which is why 5
beats the 3 that suffices for ILP alone. Changing it means editing the body.
"""
function process_segment!(t::Table, data::Vector{UInt8}, a::Int, b::Int)
    if b - a < STREAMS * MIN_STREAM_BYTES
        return scan_serial!(t, data, a, b)
    end
    span = b - a
    starts = ntuple(k -> k == 1 ? a : next_row_start(data, a + (k - 1) * span ÷ STREAMS, b),
                    Val(STREAMS))

    # `@nexprs` needs a literal, so the 5s must match STREAMS — the assert above
    # keeps them in step. Plain locals, not a container: the cursors have to stay
    # in registers.
    @nexprs 5 k -> p_k = starts[k]
    @nexprs 5 k -> e_k = (k == 5 ? b : starts[k + 1])

    while @nall 5 k -> (p_k < e_k)
        @nexprs 5 k -> name_k = scan_name(data, p_k)
        @nexprs 5 k -> (p_k = finish_row!(t, data, p_k, name_k))
    end
    @nexprs 5 k -> scan_serial!(t, data, p_k, e_k)
    return nothing
end

"""
    scan_parallel(data, fend) -> Vector{Table}

One task per thread, each pulling segments off the queue until it drains — a
fixed 1/N split would leave everyone waiting on the slowest.

Each `Table` is allocated inside its own task, which avoids false sharing and
puts it on memory local to that task's NUMA node. Captures are bound with `let`
so the closure cannot need a `Core.Box`.
"""
function scan_parallel(data::Vector{UInt8}, fend::Int)
    fend <= 1 && return Table[]
    nseg = cld(fend, SEGMENT_SIZE)
    work = Work(nseg)
    ntask = max(1, min(Threads.nthreads(), nseg))
    tasks = Vector{Task}(undef, ntask)
    for i in 1:ntask
        tasks[i] = let data = data, fend = fend, work = work
            Threads.@spawn begin
                tbl = Table()
                while (seg = claim!(work)) != 0
                    a = segment_start(data, seg, fend)
                    b = segment_start(data, seg + 1, fend)
                    process_segment!(tbl, data, a, b)
                end
                tbl
            end
        end
    end
    return Table[fetch(t)::Table for t in tasks]
end

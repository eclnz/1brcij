# Segmentation, work queue, and the per-thread scan.

const SEGMENT_SIZE = 1 << 21      # 2 MiB: balances without losing prefetch
const STREAMS = 3
const MIN_STREAM_BYTES = 1 << 14  # below this a segment is scanned serially

"""
    Work

Atomic segment counter, the only shared mutable state in the program.
"""
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

"""
    next_row_start(base, off, limit) -> Int

First byte after the next newline at or after `off`, clamped to `limit`.
"""
@inline function next_row_start(base::Ptr{UInt8}, off::Int, limit::Int)
    while off < limit && unsafe_load(base + off) != NEWLINE
        off += 1
    end
    return off < limit ? off + 1 : limit
end

"""
    segment_start(base, seg, fend) -> Int

Start of segment `seg` (1-based) within `[0, fend)`, repaired to a row boundary.

A segment's stop is `segment_start(base, seg + 1, fend)` — the same function, so
neighbouring threads agree by construction and every row is scanned once.
"""
@inline function segment_start(base::Ptr{UInt8}, seg::Int, fend::Int)
    seg == 1 && return 0
    off = (seg - 1) * SEGMENT_SIZE
    off >= fend && return fend
    return next_row_start(base, off, fend)
end

"""
    process_row!(t, base, pos) -> Int

Handle one `<name>;<value>\\n` row and return the offset of the next.
"""
@inline function process_row!(t::Table, base::Ptr{UInt8}, pos::Int)
    h, nend, k0, k1 = scan_name(base, pos)
    vstart = nend + 1
    v, adv = parse_value(unsafe_load(Ptr{UInt64}(base + vstart)))
    update!(t, base, h, pos, nend - pos, k0, k1, v)
    return vstart + adv
end

@inline function scan_serial!(t::Table, base::Ptr{UInt8}, pos::Int, stop::Int)
    while pos < stop
        pos = process_row!(t, base, pos)
    end
    return nothing
end

"""
    process_segment!(t, base, a, b)

Scan `[a, b)`, which must begin on a row boundary.

Row *n+1*'s position is only known once row *n* is parsed, so a single cursor is
one long dependency chain and every cache miss stalls everything behind it.
`STREAMS` sub-ranges advanced round-robin give the out-of-order engine
independent chains to overlap, while each still reads sequentially. The cursors
are plain locals so they stay in registers.
"""
function process_segment!(t::Table, base::Ptr{UInt8}, a::Int, b::Int)
    if b - a < STREAMS * MIN_STREAM_BYTES
        return scan_serial!(t, base, a, b)
    end
    span = b - a
    p1 = a
    p2 = next_row_start(base, a + span ÷ 3, b)
    p3 = next_row_start(base, a + (2 * span) ÷ 3, b)
    e1, e2, e3 = p2, p3, b

    while p1 < e1 && p2 < e2 && p3 < e3
        p1 = process_row!(t, base, p1)
        p2 = process_row!(t, base, p2)
        p3 = process_row!(t, base, p3)
    end
    scan_serial!(t, base, p1, e1)
    scan_serial!(t, base, p2, e2)
    scan_serial!(t, base, p3, e3)
    return nothing
end

"""
    scan_parallel(base, fend) -> Vector{Table}

One task per thread, each pulling segments off the queue until it is empty.
Threads finish segments at different rates, so a fixed 1/N split of the file
would leave everyone waiting on the slowest.

Each `Table` is allocated inside its own task: separate allocations avoid false
sharing and land on memory local to whichever NUMA node the task runs on.
Captures are bound with `let` so the closure cannot need a `Core.Box`.
"""
function scan_parallel(base::Ptr{UInt8}, fend::Int)
    fend <= 0 && return Table[]
    nseg = cld(fend, SEGMENT_SIZE)
    work = Work(nseg)
    ntask = max(1, min(Threads.nthreads(), nseg))
    tasks = Vector{Task}(undef, ntask)
    for i in 1:ntask
        tasks[i] = let base = base, fend = fend, work = work
            Threads.@spawn begin
                tbl = Table()
                # tbl is addressed through a raw pointer into its own array.
                GC.@preserve tbl while (seg = claim!(work)) != 0
                    a = segment_start(base, seg, fend)
                    b = segment_start(base, seg + 1, fend)
                    process_segment!(tbl, base, a, b)
                end
                tbl
            end
        end
    end
    return Table[fetch(t)::Table for t in tasks]
end

# Segmentation, work queue, and the per-thread scan.

using Base.Cartesian: @nexprs, @nall

const SEGMENT_SIZE = 1 << 21      # 2 MiB: balances without losing prefetch
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

"""First byte after the next newline at or after `off`, clamped to `limit`."""
@inline function next_row_start(base::Ptr{UInt8}, off::Int, limit::Int)
    while off < limit && unsafe_load(base + off) != NEWLINE
        off += 1
    end
    return off < limit ? off + 1 : limit
end

"""
    segment_start(base, seg, fend) -> Int

Start of segment `seg` (1-based), repaired to a row boundary. A segment's stop
is this same function applied to `seg + 1`, so neighbouring threads agree by
construction and every row is scanned once.
"""
@inline function segment_start(base::Ptr{UInt8}, seg::Int, fend::Int)
    seg == 1 && return 0
    off = (seg - 1) * SEGMENT_SIZE
    off >= fend && return fend
    return next_row_start(base, off, fend)
end

# No prefetch intrinsic in Julia, so hand-written IR — the most fragile code
# here. Arguments are (address, write, locality, data cache); write, because the
# entry is read-modify-written. Lowers to nothing where the target lacks it.
@inline function prefetch(p::Ptr)
    Base.llvmcall(("""
        declare void @llvm.prefetch.p0(ptr, i32, i32, i32)
        define void @entry(i64 %p) #0 {
            %ptr = inttoptr i64 %p to ptr
            call void @llvm.prefetch.p0(ptr %ptr, i32 1, i32 3, i32 1)
            ret void
        }
        attributes #0 = { alwaysinline }
        """, "entry"), Cvoid, Tuple{UInt64}, UInt64(p))
end

@inline slot(t::Table, h::UInt64) = entry(t, Int(h & TABLE_MASK))

"""Parse the value, accumulate, and return the offset of the next row."""
@inline function finish_row!(t::Table, base::Ptr{UInt8}, pos::Int, name::Name)
    vstart = name.stop + 1
    v, adv = parse_value(unsafe_load(Ptr{UInt64}(base + vstart)))
    update!(t, base, pos, name, v)
    return vstart + adv
end

"""One `<name>;<value>` row; returns the offset of the next."""
@inline function process_row!(t::Table, base::Ptr{UInt8}, pos::Int)
    return finish_row!(t, base, pos, scan_name(base, pos))
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

Row *n+1*'s position is unknown until row *n* is parsed, so one cursor is a
single dependency chain where every cache miss stalls everything behind it.
`STREAMS` sub-ranges advanced round-robin give the out-of-order engine
independent chains to overlap, each still read sequentially.

Hashing every stream before parsing any of them puts four rows of work between
each prefetch and its use. That distance is the point: prefetching just before
the probe measures flat, and pipelining without prefetching measures flat too.
So `STREAMS` sets prefetch distance as well as chain count, which is why 5 beats
the 3 that suffices for ILP alone. Changing it means editing the body below.
"""
function process_segment!(t::Table, base::Ptr{UInt8}, a::Int, b::Int)
    if b - a < STREAMS * MIN_STREAM_BYTES
        return scan_serial!(t, base, a, b)
    end
    span = b - a
    starts = ntuple(k -> k == 1 ? a : next_row_start(base, a + (k - 1) * span ÷ STREAMS, b),
                    Val(STREAMS))

    # `@nexprs` needs a literal, so the 5s must match STREAMS — the assert above
    # keeps them in step. Plain locals, not a container: the cursors have to stay
    # in registers.
    @nexprs 5 k -> p_k = starts[k]
    @nexprs 5 k -> e_k = (k == 5 ? b : starts[k + 1])

    while @nall 5 k -> (p_k < e_k)
        @nexprs 5 k -> begin
            name_k = scan_name(base, p_k)
            prefetch(slot(t, name_k.hash))
        end
        @nexprs 5 k -> (p_k = finish_row!(t, base, p_k, name_k))
    end
    @nexprs 5 k -> scan_serial!(t, base, p_k, e_k)
    return nothing
end

"""
    scan_parallel(base, fend) -> Vector{Table}

One task per thread, each pulling segments off the queue until it drains — a
fixed 1/N split would leave everyone waiting on the slowest.

Each `Table` is allocated inside its own task, which avoids false sharing and
puts it on memory local to that task's NUMA node. Captures are bound with `let`
so the closure cannot need a `Core.Box`.
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

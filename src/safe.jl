"""
    OneBRC.Safe

The same algorithm without any of the unsafe machinery: no `unsafe_load`, no raw
pointers, no `llvmcall`, no `@inbounds`, and bounds checking left on. Kept to
measure what the unsafe version actually buys.

Two optimisations have no safe equivalent and are simply absent: the 16-byte
`vpcmpeqb` delimiter scan and the table prefetch. Everything else — the segment
queue, the five pipelined cursors, SWAR scanning, the branchless value parse and
the cache-line-packed table — carries over unchanged.
"""
module Safe

using Mmap
using ..OneBRC: Stat, combine, TABLE_BITS, TABLE_SIZE, TABLE_MASK, MAX_ENTRIES,
                SEGMENT_SIZE, STREAMS, MIN_STREAM_BYTES, NEWLINE, SEMICOLON,
                ONES, HIGHS, SEMIS, HASH_BASIS, HASH_PRIME,
                DOT_BITS, SIGN_BYTE, DIGIT_MASK, DIGIT_MUL, ABS_MASK,
                INLINE_KEY_BYTES, TAIL_SLACK, MAX_ROW_BYTES, accumulate_slow!

# 1-based indices throughout, unlike the pointer version's 0-based offsets.

"""Little-endian 8-byte load, assembled from bytes so it stays bounds checked."""
@inline function load8(d::Vector{UInt8}, i::Int)
    return UInt64(d[i])       | UInt64(d[i + 1]) << 8  | UInt64(d[i + 2]) << 16 |
           UInt64(d[i + 3]) << 24 | UInt64(d[i + 4]) << 32 | UInt64(d[i + 5]) << 40 |
           UInt64(d[i + 6]) << 48 | UInt64(d[i + 7]) << 56
end

@inline match_bytes(w::UInt64, p::UInt64) = ((w ⊻ p) - ONES) & ~(w ⊻ p) & HIGHS
@inline tail_mask(n::Int) = typemax(UInt64) >> (64 - 8 * n)
@inline mix(h::UInt64, w::UInt64) = (h ⊻ w) * HASH_PRIME
@inline finalize_hash(h::UInt64) = h ⊻ (h >> 29)

struct Name
    hash::UInt64
    stop::Int          # 1-based index of the ';'
    key0::UInt64
    key1::UInt64
end

"""SWAR delimiter scan — the safe stand-in for the 16-byte vector compare."""
@inline function scan_name(d::Vector{UInt8}, pos::Int)
    w0 = load8(d, pos)
    m0 = match_bytes(w0, SEMIS)
    if m0 != 0
        n = trailing_zeros(m0) >> 3
        k0 = w0 & tail_mask(n)
        return Name(finalize_hash(mix(mix(HASH_BASIS, k0), UInt64(0))), pos + n, k0, UInt64(0))
    end
    w1 = load8(d, pos + 8)
    m1 = match_bytes(w1, SEMIS)
    if m1 != 0
        n = trailing_zeros(m1) >> 3
        k1 = w1 & tail_mask(n)
        return Name(finalize_hash(mix(mix(HASH_BASIS, w0), k1)), pos + 8 + n, w0, k1)
    end
    return scan_name_long(d, pos, w0, w1)
end

@noinline function scan_name_long(d::Vector{UInt8}, pos::Int, w0::UInt64, w1::UInt64)
    h = mix(mix(HASH_BASIS, w0), w1)
    p = pos + 16
    while true
        w = load8(d, p)
        m = match_bytes(w, SEMIS)
        if m != 0
            n = trailing_zeros(m) >> 3
            return Name(finalize_hash(mix(h, w & tail_mask(n))), p + n, w0, w1)
        end
        h = mix(h, w)
        p += 8
    end
end

@inline function parse_value(word::UInt64)
    w = reinterpret(Int64, word)
    dot = trailing_zeros(~word & DOT_BITS)
    signed = (reinterpret(Int64, ~word) << 59) >> 63
    design = ~(signed & SIGN_BYTE)
    digits = ((w & design) << (28 - dot)) & DIGIT_MASK
    absval = ((digits * DIGIT_MUL) >>> 32) & ABS_MASK
    return (absval ⊻ signed) - signed, (dot >> 3) + 3
end

# Four UInt64 slots per entry, so one entry still occupies one cache line. The
# count, min and max share the fourth because a Vector{UInt64} cannot be
# reinterpreted at a byte offset without the pointer casts this module avoids.
const SLOTS = 4
const TEMP_BIAS = 1000

struct Table
    w::Vector{UInt64}      # key0, key1, sum, packed(cnt | min<<32 | max<<48)
    off::Vector{Int}
    len::Vector{Int32}
    nlive::Base.RefValue{Int}
end

Table() = Table(zeros(UInt64, SLOTS * TABLE_SIZE), zeros(Int, TABLE_SIZE),
                zeros(Int32, TABLE_SIZE), Ref(0))

@noinline table_full() = error("more than $MAX_ENTRIES distinct station names")

@inline function name_tail_eq(d::Vector{UInt8}, a::Int, b::Int, len::Int)
    i = INLINE_KEY_BYTES
    while i + 8 <= len
        load8(d, a + i) == load8(d, b + i) || return false
        i += 8
    end
    m = tail_mask(len - i)
    return (load8(d, a + i) & m) == (load8(d, b + i) & m)
end

@inline function update!(t::Table, d::Vector{UInt8}, pos::Int, name::Name, v::Int64)
    vb = UInt64(v + TEMP_BIAS)
    idx = Int(name.hash & TABLE_MASK)
    while true
        b = SLOTS * idx + 1
        acc = t.w[b + 3]
        if acc == 0
            n = t.nlive[] + 1
            n > MAX_ENTRIES && table_full()
            t.nlive[] = n
            t.w[b] = name.key0
            t.w[b + 1] = name.key1
            t.w[b + 2] = reinterpret(UInt64, v)
            t.w[b + 3] = UInt64(1) | (vb << 32) | (vb << 48)
            t.off[idx + 1] = pos
            t.len[idx + 1] = Int32(name.stop - pos)
            return nothing
        elseif t.w[b] == name.key0 && t.w[b + 1] == name.key1 &&
               (name.stop - pos < INLINE_KEY_BYTES ||
                (t.len[idx + 1] == Int32(name.stop - pos) &&
                 name_tail_eq(d, t.off[idx + 1], pos, name.stop - pos)))
            minb = (acc >> 32) % UInt16
            maxb = (acc >> 48) % UInt16
            acc += 1
            vb16 = vb % UInt16
            if (vb16 - minb) > (maxb - minb)
                acc = vb16 < minb ? (acc & 0xffff0000ffffffff) | (vb << 32) :
                                    (acc & 0x0000ffffffffffff) | (vb << 48)
            end
            t.w[b + 3] = acc
            t.w[b + 2] = reinterpret(UInt64, reinterpret(Int64, t.w[b + 2]) + v)
            return nothing
        end
        idx = (idx + 1) & Int(TABLE_MASK)
    end
end

@inline function finish_row!(t::Table, d::Vector{UInt8}, pos::Int, name::Name)
    vstart = name.stop + 1
    v, adv = parse_value(load8(d, vstart))
    update!(t, d, pos, name, v)
    return vstart + adv
end

@inline process_row!(t, d, pos) = finish_row!(t, d, pos, scan_name(d, pos))

@inline function scan_serial!(t::Table, d::Vector{UInt8}, pos::Int, stop::Int)
    while pos < stop
        pos = process_row!(t, d, pos)
    end
end

@inline function next_row_start(d::Vector{UInt8}, i::Int, limit::Int)
    while i < limit && d[i] != NEWLINE
        i += 1
    end
    return i < limit ? i + 1 : limit
end

function process_segment!(t::Table, d::Vector{UInt8}, a::Int, b::Int)
    if b - a < STREAMS * MIN_STREAM_BYTES
        return scan_serial!(t, d, a, b)
    end
    span = b - a
    p1 = a
    p2 = next_row_start(d, a + span ÷ 5, b)
    p3 = next_row_start(d, a + (2 * span) ÷ 5, b)
    p4 = next_row_start(d, a + (3 * span) ÷ 5, b)
    p5 = next_row_start(d, a + (4 * span) ÷ 5, b)
    e1, e2, e3, e4, e5 = p2, p3, p4, p5, b
    while p1 < e1 && p2 < e2 && p3 < e3 && p4 < e4 && p5 < e5
        n1 = scan_name(d, p1); n2 = scan_name(d, p2); n3 = scan_name(d, p3)
        n4 = scan_name(d, p4); n5 = scan_name(d, p5)
        p1 = finish_row!(t, d, p1, n1); p2 = finish_row!(t, d, p2, n2)
        p3 = finish_row!(t, d, p3, n3); p4 = finish_row!(t, d, p4, n4)
        p5 = finish_row!(t, d, p5, n5)
    end
    scan_serial!(t, d, p1, e1); scan_serial!(t, d, p2, e2); scan_serial!(t, d, p3, e3)
    scan_serial!(t, d, p4, e4); scan_serial!(t, d, p5, e5)
    return nothing
end

@inline function segment_start(d::Vector{UInt8}, seg::Int, fend::Int)
    seg == 1 && return 1
    i = (seg - 1) * SEGMENT_SIZE + 1
    i >= fend && return fend
    return next_row_start(d, i, fend)
end

function scan_parallel(d::Vector{UInt8}, fend::Int)
    fend <= 1 && return Table[]
    nseg = cld(fend, SEGMENT_SIZE)
    counter = Threads.Atomic{Int}(1)
    ntask = max(1, min(Threads.nthreads(), nseg))
    tasks = Vector{Task}(undef, ntask)
    for i in 1:ntask
        tasks[i] = let d = d, fend = fend, counter = counter, nseg = nseg
            Threads.@spawn begin
                tbl = Table()
                while true
                    seg = Threads.atomic_add!(counter, 1)
                    seg > nseg && break
                    process_segment!(tbl, d, segment_start(d, seg, fend),
                                     segment_start(d, seg + 1, fend))
                end
                tbl
            end
        end
    end
    return Table[fetch(t)::Table for t in tasks]
end

function merge_tables(tables, d::Vector{UInt8})
    out = Dict{String,Stat}()
    for t in tables, i in 0:(TABLE_SIZE - 1)
        acc = t.w[SLOTS * i + 4]
        acc == 0 && continue
        a = t.off[i + 1]
        name = String(d[a:(a + t.len[i + 1] - 1)])
        s = Stat(Int64((acc >> 32) % UInt16) - TEMP_BIAS,
                 Int64((acc >> 48) % UInt16) - TEMP_BIAS,
                 reinterpret(Int64, t.w[SLOTS * i + 3]), Int64(acc % UInt32))
        prev = get(out, name, nothing)
        out[name] = prev === nothing ? s : combine(prev, s)
    end
    return out
end

"""Same carve-out as the unsafe path, so the two read identical row sets."""
function fast_region_end(d::Vector{UInt8}, fsize::Int)
    fsize <= TAIL_SLACK && return 1
    from = fsize - TAIL_SLACK
    stop = min(from + MAX_ROW_BYTES, fsize)
    i = from
    while i < stop
        d[i] == NEWLINE && return i + 1
        i += 1
    end
    return 1
end

function run_file(path::AbstractString)
    io = open(path, "r")
    try
        fsize = Int(filesize(io))
        fsize == 0 && return Dict{String,Stat}()
        d = Mmap.mmap(io, Vector{UInt8}, fsize)
        fend = fast_region_end(d, fsize)
        stats = merge_tables(scan_parallel(d, fend), d)
        accumulate_slow!(stats, d, fend - 1, fsize)
        return stats
    finally
        close(io)
    end
end

end # module Safe

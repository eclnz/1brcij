# Open-addressing table, one per thread, nothing shared.
#
# A Dict would mean materialising a String key per row. This never resizes (the
# spec caps the station set at 10 000) and splits each slot in two: 32 hot bytes
# every row touches, and the name's offset and length, read only on insert, for
# names of 16 bytes or more, and at merge. That halves the hot working set.

const TABLE_BITS = 15
const TABLE_SIZE = 1 << TABLE_BITS
const TABLE_MASK = UInt64(TABLE_SIZE - 1)

# Two entries per cache line, which suits linear probing: a miss brings the
# neighbour in for free.
const ENTRY_BYTES = 32
const O_KEY0 = 0     # UInt64, name bytes 1..8,  masked to length
const O_KEY1 = 8     # UInt64, name bytes 9..16, masked to length
const O_SUM  = 16    # Int64, tenths
const O_CNT  = 24    # Int32, 0 marks an empty slot
const O_MIN  = 28    # Int16, tenths fit in ±999
const O_MAX  = 30    # Int16

const INLINE_KEY_BYTES = 16

# Overfilling would leave the probe loop hunting an empty slot forever — a hang,
# not a wrong answer. Half also keeps linear probing fast.
const MAX_ENTRIES = TABLE_SIZE ÷ 2

struct Table
    data::Vector{Int64}    # hot entries, 64-byte aligned
    base::Ptr{UInt8}
    off::Vector{Int}       # cold: name offset into the mapping, per slot
    len::Vector{Int32}     # cold: name length, per slot
    nlive::Base.RefValue{Int}
end

function Table()
    # Julia guarantees no alignment for array data, so align by hand.
    data = zeros(Int64, (ENTRY_BYTES ÷ 8) * (TABLE_SIZE + 2))
    p = Ptr{UInt8}(pointer(data))
    pad = -Int(UInt(p)) & 63
    return Table(data, p + pad, zeros(Int, TABLE_SIZE), zeros(Int32, TABLE_SIZE), Ref(0))
end

@inline entry(t::Table, idx::Int) = t.base + idx * ENTRY_BYTES
@inline ld(::Type{T}, e::Ptr{UInt8}, off::Int) where {T} = unsafe_load(Ptr{T}(e + off))
@inline st!(e::Ptr{UInt8}, off::Int, v::T) where {T} = unsafe_store!(Ptr{T}(e + off), v)

@noinline table_full() = error(
    "more than $MAX_ENTRIES distinct station names in one thread's table; " *
    "the challenge caps the station set at 10000, so either the input is out " *
    "of spec or TABLE_BITS (currently $TABLE_BITS) needs raising")

"""Compare two names of equal length past the 16 bytes already matched."""
@inline function name_tail_eq(base::Ptr{UInt8}, a::Int, b::Int, len::Int)
    i = INLINE_KEY_BYTES
    while i + 8 <= len
        unsafe_load(Ptr{UInt64}(base + a + i)) ==
        unsafe_load(Ptr{UInt64}(base + b + i)) || return false
        i += 8
    end
    m = tail_mask(len - i)
    return (unsafe_load(Ptr{UInt64}(base + a + i)) & m) ==
           (unsafe_load(Ptr{UInt64}(base + b + i)) & m)
end

"""A count of zero can only mean untouched."""
@inline slot_free(e::Ptr{UInt8}) = ld(Int32, e, O_CNT) == 0

"""
    slot_matches(t, e, base, idx, pos, name) -> Bool

A name under 16 bytes leaves a zero byte in `key1` from the masking, and names
contain no NUL, so the inline key implies the length too. Only names of 16 bytes
or more can collide with a longer one sharing their first 16; those consult the
cold length and offset, which is what keeps the length out of the hot entry.
"""
@inline function slot_matches(t::Table, e::Ptr{UInt8}, base::Ptr{UInt8},
                              idx::Int, pos::Int, name::Name)
    ld(UInt64, e, O_KEY0) == name.key0 || return false
    ld(UInt64, e, O_KEY1) == name.key1 || return false
    nlen = name.stop - pos
    nlen < INLINE_KEY_BYTES && return true
    @inbounds return t.len[idx + 1] == Int32(nlen) &&
                    name_tail_eq(base, t.off[idx + 1], pos, nlen)
end

"""Claim an empty slot for `name`."""
@inline function slot_claim!(t::Table, e::Ptr{UInt8}, idx::Int, pos::Int,
                             name::Name, v::Int64)
    n = t.nlive[] + 1              # per station, not per row
    n > MAX_ENTRIES && table_full()
    t.nlive[] = n
    st!(e, O_KEY0, name.key0)
    st!(e, O_KEY1, name.key1)
    st!(e, O_SUM, v)
    st!(e, O_CNT, Int32(1))
    st!(e, O_MIN, Int16(v))
    st!(e, O_MAX, Int16(v))
    @inbounds t.off[idx + 1] = pos
    @inbounds t.len[idx + 1] = Int32(name.stop - pos)
    return nothing
end

"""Fold one reading into a slot already holding this station."""
@inline function slot_accumulate!(e::Ptr{UInt8}, v::Int64)
    v16 = Int16(v)
    v16 < ld(Int16, e, O_MIN) && st!(e, O_MIN, v16)
    v16 > ld(Int16, e, O_MAX) && st!(e, O_MAX, v16)
    st!(e, O_SUM, ld(Int64, e, O_SUM) + v)
    st!(e, O_CNT, ld(Int32, e, O_CNT) + Int32(1))
    return nothing
end

"""Insert or accumulate one row, probing linearly from the hash."""
@inline function update!(t::Table, base::Ptr{UInt8}, pos::Int, name::Name, v::Int64)
    idx = Int(name.hash & TABLE_MASK)
    while true
        e = entry(t, idx)
        if slot_free(e)
            return slot_claim!(t, e, idx, pos, name, v)
        elseif slot_matches(t, e, base, idx, pos, name)
            return slot_accumulate!(e, v)
        end
        idx = (idx + 1) & Int(TABLE_MASK)    # power of two: mask, not branch
    end
end

"""Per-station statistics, in tenths of a degree."""
struct Stat
    min::Int64
    max::Int64
    sum::Int64
    cnt::Int64
end

@inline combine(a::Stat, b::Stat) =
    Stat(min(a.min, b.min), max(a.max, b.max), a.sum + b.sum, a.cnt + b.cnt)

"""Reconcile the per-thread tables. The only place a `String` is created."""
function merge_tables(tables, base::Ptr{UInt8})
    out = Dict{String,Stat}()
    for t in tables
        GC.@preserve t for i in 0:(TABLE_SIZE - 1)
            e = entry(t, i)
            ld(Int32, e, O_CNT) == 0 && continue
            name = unsafe_string(base + t.off[i + 1], t.len[i + 1])
            s = Stat(ld(Int16, e, O_MIN), ld(Int16, e, O_MAX),
                     ld(Int64, e, O_SUM), ld(Int32, e, O_CNT))
            prev = get(out, name, nothing)
            out[name] = prev === nothing ? s : combine(prev, s)
        end
    end
    return out
end

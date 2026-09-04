# Open-addressing table, one per thread, nothing shared.
#
# A Dict would mean materialising a String key per row. This never resizes (the
# spec caps the station set at 10 000) and splits each slot in two: a 32-byte
# entry every row touches, and the name's offset and length, read only on insert,
# for names of 16 bytes or more, and at merge. That halves the hot working set.

const TABLE_BITS = 15
const TABLE_SIZE = 1 << TABLE_BITS
const TABLE_MASK = UInt64(TABLE_SIZE - 1)

const INLINE_KEY_BYTES = 16

# Overfilling would leave the probe loop hunting an empty slot forever — a hang,
# not a wrong answer. Half also keeps linear probing fast.
const MAX_ENTRIES = TABLE_SIZE ÷ 2

# Temperatures are stored biased so min/max fit UInt16 and the entry stays at
# 32 bytes: two per cache line, which suits linear probing, since a miss brings
# the neighbour in for free.
const TEMP_BIAS = 1000

"""One slot. `cnt == 0` marks it free; the key is the name's first 16 bytes."""
struct Entry
    key0::UInt64
    key1::UInt64
    sum::Int64
    cnt::UInt32
    lo::UInt16
    hi::UInt16
end

Entry() = Entry(0, 0, 0, 0, 0, 0)

struct Table
    e::Vector{Entry}
    off::Vector{Int}       # cold: name index into the mapping, per slot
    len::Vector{Int32}     # cold: name length, per slot
    nlive::Base.RefValue{Int}
end

Table() = Table(fill(Entry(), TABLE_SIZE), zeros(Int, TABLE_SIZE),
                zeros(Int32, TABLE_SIZE), Ref(0))

@noinline table_full() = error(
    "more than $MAX_ENTRIES distinct station names in one thread's table; " *
    "the challenge caps the station set at 10000, so either the input is out " *
    "of spec or TABLE_BITS (currently $TABLE_BITS) needs raising")

"""Compare two names of equal length past the 16 bytes already matched."""
@inline function name_tail_eq(data::Vector{UInt8}, a::Int, b::Int, len::Int)
    i = INLINE_KEY_BYTES
    while i + 8 <= len
        load8(data, a + i) == load8(data, b + i) || return false
        i += 8
    end
    m = tail_mask(len - i)
    return (load8(data, a + i) & m) == (load8(data, b + i) & m)
end

"""
    slot_matches(t, e, data, i, pos, name, len) -> Bool

A name under 16 bytes leaves a zero byte in `key1` from the masking, and names
contain no NUL, so the inline key implies the length too. Only names of 16 bytes
or more can collide with a longer one sharing their first 16; those consult the
cold length and offset, which is what keeps the length out of the hot entry.
"""
@inline function slot_matches(t::Table, e::Entry, data::Vector{UInt8},
                              i::Int, pos::Int, name::Name, len::Int)
    e.key0 == name.key0 || return false
    e.key1 == name.key1 || return false
    len < INLINE_KEY_BYTES && return true
    @inbounds return t.len[i] == Int32(len) && name_tail_eq(data, t.off[i], pos, len)
end

"""Insert or accumulate one row, probing linearly from the hash."""
@inline function update!(t::Table, data::Vector{UInt8}, pos::Int, name::Name, v::Int64)
    vb = UInt16(v + TEMP_BIAS)
    len = name.stop - pos
    i = Int(name.hash & TABLE_MASK) + 1
    @inbounds while true
        e = t.e[i]
        if e.cnt == 0
            n = t.nlive[] + 1              # per station, not per row
            n > MAX_ENTRIES && table_full()
            t.nlive[] = n
            t.e[i] = Entry(name.key0, name.key1, v, 1, vb, vb)
            t.off[i] = pos
            t.len[i] = Int32(len)
            return nothing
        elseif slot_matches(t, e, data, i, pos, name, len)
            t.e[i] = Entry(e.key0, e.key1, e.sum + v, e.cnt + UInt32(1),
                           min(e.lo, vb), max(e.hi, vb))
            return nothing
        end
        i = (i & Int(TABLE_MASK)) + 1      # power of two: mask, not branch
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
function merge_tables(tables, data::Vector{UInt8})
    out = Dict{String,Stat}()
    @inbounds for t in tables, i in 1:TABLE_SIZE
        e = t.e[i]
        e.cnt == 0 && continue
        a = t.off[i]
        name = String(data[a:(a + t.len[i] - 1)])
        s = Stat(Int64(e.lo) - TEMP_BIAS, Int64(e.hi) - TEMP_BIAS, e.sum, Int64(e.cnt))
        prev = get(out, name, nothing)
        out[name] = prev === nothing ? s : combine(prev, s)
    end
    return out
end

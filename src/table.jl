# ---------------------------------------------------------------------------
# Layer 6: a purpose-built open-addressing hash table.
#
# `Dict{String,...}` is unusable here because hashing a `String` key means
# materialising one, which is an allocation and a copy per row.  Instead:
#
#   * open addressing with linear probing over a fixed power-of-two table, so
#     it never resizes (the challenge caps the station set at 10 000 names);
#   * one entry per 64-byte cache line (array-of-structs): an update touches
#     one line rather than the seven a struct-of-arrays layout would;
#   * the key is stored as an OFFSET INTO THE MMAP plus a length, so the name
#     bytes are never copied.  The mapping outlives every table.
#
# Each thread owns a table outright; nothing here is shared or synchronised.
# ---------------------------------------------------------------------------

const TABLE_BITS = 17
const TABLE_SIZE = 1 << TABLE_BITS          # 131072 slots: load factor < 0.08
const TABLE_MASK = UInt64(TABLE_SIZE - 1)

# One entry occupies exactly one 64-byte cache line: seven Int64 fields and a
# word of padding.  This is array-of-structs, not the struct-of-arrays layout
# it replaces, and the reason is cache traffic — with seven parallel arrays a
# single row's update touches up to seven different cache lines, where this
# touches one.
const ENTRY_WORDS = 8                     # Int64 slots per entry
const ENTRY_BYTES = ENTRY_WORDS * 8       # == 64, one cache line
const E_HASH = 0
const E_OFF  = 1
const E_LEN  = 2
const E_MIN  = 3                          # all statistics are in tenths
const E_MAX  = 4
const E_SUM  = 5
const E_CNT  = 6                          # 0 marks an empty slot
# slot 7 is padding to fill the line

struct Table
    data::Vector{Int64}    # backing store, over-allocated by one entry
    base::Ptr{Int64}       # 64-byte aligned pointer into `data`
end

function Table()
    # Julia guarantees no particular alignment for array data, and an entry
    # straddling two cache lines would defeat the whole point, so over-allocate
    # by one entry and start at the next 64-byte boundary.
    data = zeros(Int64, ENTRY_WORDS * (TABLE_SIZE + 1))
    p = pointer(data)
    pad = (-Int(UInt(p)) & (ENTRY_BYTES - 1)) ÷ 8
    return Table(data, p + 8 * pad)
end

# `cnt == 0` is the empty marker and an insert writes min and max outright, so
# zeroed memory is a valid empty table — there are no sentinels to fill in.
@inline entry(t::Table, idx::Int) = t.base + idx * ENTRY_BYTES
@inline field(e::Ptr{Int64}, f::Int) = unsafe_load(e + 8 * f)
@inline setfield(e::Ptr{Int64}, f::Int, v::Int64) = unsafe_store!(e + 8 * f, v)

"""
    name_eq(base, a, b, len) -> Bool

Compare two names of equal length held at offsets `a` and `b` in the mapping,
eight bytes at a time with a masked final word.  Reads up to 7 bytes past each
name, which the caller's tail carve-out makes safe.
"""
@inline function name_eq(base::Ptr{UInt8}, a::Int, b::Int, len::Int)
    i = 0
    while i + 8 <= len
        unsafe_load(Ptr{UInt64}(base + a + i)) ==
        unsafe_load(Ptr{UInt64}(base + b + i)) || return false
        i += 8
    end
    m = tail_mask(len - i)
    return (unsafe_load(Ptr{UInt64}(base + a + i)) & m) ==
           (unsafe_load(Ptr{UInt64}(base + b + i)) & m)
end

"""
    update!(t, base, h, noff, nlen, v)

Insert or accumulate one row.  The hash is compared first so that the full name
comparison is rare; the full comparison is what makes this correct rather than
merely probably correct.

`cnt == 0` marks an empty slot: every live entry has seen at least one row.
`scan_name` has already run the hash through `finalize_hash`, so the low bits
are safe to index on directly.
"""
@inline function update!(t::Table, base::Ptr{UInt8}, h::UInt64,
                         noff::Int, nlen::Int, v::Int64)
    hi = reinterpret(Int64, h)
    idx = Int(h & TABLE_MASK)
    while true
        e = entry(t, idx)
        if field(e, E_CNT) == 0
            setfield(e, E_HASH, hi)
            setfield(e, E_OFF, noff)
            setfield(e, E_LEN, nlen)
            setfield(e, E_MIN, v)
            setfield(e, E_MAX, v)
            setfield(e, E_SUM, v)
            setfield(e, E_CNT, 1)
            return nothing
        elseif field(e, E_HASH) == hi && field(e, E_LEN) == nlen &&
               name_eq(base, field(e, E_OFF), noff, nlen)
            v < field(e, E_MIN) && setfield(e, E_MIN, v)
            v > field(e, E_MAX) && setfield(e, E_MAX, v)
            setfield(e, E_SUM, field(e, E_SUM) + v)
            setfield(e, E_CNT, field(e, E_CNT) + 1)
            return nothing
        end
        # The table is a power of two, so wrapping is a mask, not a branch.
        idx = (idx + 1) & Int(TABLE_MASK)
    end
end

"""Aggregated statistics for one station, in tenths of a degree."""
struct Stat
    min::Int64
    max::Int64
    sum::Int64
    cnt::Int64
end

@inline combine(a::Stat, b::Stat) =
    Stat(min(a.min, b.min), max(a.max, b.max), a.sum + b.sum, a.cnt + b.cnt)

"""
    merge_tables(tables, base) -> Dict{String,Stat}

Reconcile the per-thread tables.  This is the only place a `String` is ever
created: at most a few tens of thousands of times, against a billion in the
naive version.
"""
function merge_tables(tables, base::Ptr{UInt8})
    out = Dict{String,Stat}()
    for t in tables
        GC.@preserve t for i in 0:(TABLE_SIZE - 1)
            e = entry(t, i)
            field(e, E_CNT) == 0 && continue
            name = unsafe_string(base + field(e, E_OFF), field(e, E_LEN))
            s = Stat(field(e, E_MIN), field(e, E_MAX), field(e, E_SUM), field(e, E_CNT))
            prev = get(out, name, nothing)
            out[name] = prev === nothing ? s : combine(prev, s)
        end
    end
    return out
end

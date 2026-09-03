# ---------------------------------------------------------------------------
# Layer 6: a purpose-built open-addressing hash table.
#
# `Dict{String,...}` is unusable here because hashing a `String` key means
# materialising one, which is an allocation and a copy per row.  Instead:
#
#   * open addressing with linear probing over a fixed power-of-two table, so
#     it never resizes (the challenge caps the station set at 10 000 names);
#   * struct-of-arrays rather than array-of-structs;
#   * the key is stored as an OFFSET INTO THE MMAP plus a length, so the name
#     bytes are never copied.  The mapping outlives every table.
#
# Each thread owns a table outright; nothing here is shared or synchronised.
# ---------------------------------------------------------------------------

const TABLE_BITS = 17
const TABLE_SIZE = 1 << TABLE_BITS          # 131072 slots: load factor < 0.08
const TABLE_MASK = UInt64(TABLE_SIZE - 1)

struct Table
    hash::Vector{UInt64}
    off::Vector{Int}       # 0-based offset of the name into the mmap
    len::Vector{Int32}
    min::Vector{Int32}     # all statistics are in tenths of a degree
    max::Vector{Int32}
    sum::Vector{Int64}
    cnt::Vector{Int32}
end

Table() = Table(zeros(UInt64, TABLE_SIZE),
                zeros(Int, TABLE_SIZE),
                zeros(Int32, TABLE_SIZE),
                fill(Int32(9999), TABLE_SIZE),
                fill(Int32(-9999), TABLE_SIZE),
                zeros(Int64, TABLE_SIZE),
                zeros(Int32, TABLE_SIZE))

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
    idx = Int(h & TABLE_MASK) + 1
    @inbounds while true
        if t.cnt[idx] == 0
            t.hash[idx] = h
            t.off[idx] = noff
            t.len[idx] = Int32(nlen)
            t.min[idx] = Int32(v)
            t.max[idx] = Int32(v)
            t.sum[idx] = v
            t.cnt[idx] = Int32(1)
            return nothing
        elseif t.hash[idx] == h && t.len[idx] == nlen &&
               name_eq(base, t.off[idx], noff, nlen)
            v < t.min[idx] && (t.min[idx] = Int32(v))
            v > t.max[idx] && (t.max[idx] = Int32(v))
            t.sum[idx] += v
            t.cnt[idx] += Int32(1)
            return nothing
        end
        idx = idx == TABLE_SIZE ? 1 : idx + 1
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
        @inbounds for i in 1:TABLE_SIZE
            t.cnt[i] == 0 && continue
            name = unsafe_string(base + t.off[i], t.len[i])
            s = Stat(t.min[i], t.max[i], t.sum[i], t.cnt[i])
            prev = get(out, name, nothing)
            out[name] = prev === nothing ? s : combine(prev, s)
        end
    end
    return out
end

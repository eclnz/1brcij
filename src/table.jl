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
#   * the first 16 bytes of the name are stored INSIDE the entry, so the common
#     case never reads the name back out of the mapping at all.  95% of the
#     10 000-name station set and 99% of the reference generator's 413 names
#     fit; longer names keep an offset into the mapping for the remainder.
#
# Each thread owns a table outright; nothing here is shared or synchronised.
# ---------------------------------------------------------------------------

const TABLE_BITS = 15
const TABLE_SIZE = 1 << TABLE_BITS          # 32768 slots: load factor 0.31 at the cap
const TABLE_MASK = UInt64(TABLE_SIZE - 1)

# Byte offsets of the fields within one 64-byte entry.  Every field is
# separately addressable at its natural width, so nothing has to be packed and
# unpacked on the hot path — the narrow fields are simply loaded as Int32.
const ENTRY_BYTES = 64
const O_HASH = 0     # UInt64
const O_OFF  = 8     # Int64   0-based offset of the name into the mapping
const O_SUM  = 16    # Int64   running total, in tenths
const O_KEY0 = 24    # UInt64  name bytes 1..8,  masked when the name is shorter
const O_KEY1 = 32    # UInt64  name bytes 9..16, masked or zero when shorter
const O_MIN  = 40    # Int32
const O_MAX  = 44    # Int32
const O_CNT  = 48    # Int32   0 marks an empty slot
const O_LEN  = 52    # Int32
# bytes 56..63 are spare, padding the entry out to exactly one cache line

const INLINE_KEY_BYTES = 16

# The table never resizes, so a file with more distinct stations than it has
# slots would leave the probe loop searching forever for an empty one: not a
# wrong answer but a hang, which is a worse way to fail.  Refuse past half full,
# which also keeps linear probing in the regime where it is fast.
const MAX_ENTRIES = TABLE_SIZE ÷ 2

struct Table
    data::Vector{Int64}    # backing store, over-allocated by one entry
    base::Ptr{UInt8}       # 64-byte aligned pointer into `data`
    nlive::Base.RefValue{Int}
end

function Table()
    # Julia guarantees no particular alignment for array data, and an entry
    # straddling two cache lines would defeat the whole point, so over-allocate
    # by one entry and start at the next 64-byte boundary.
    data = zeros(Int64, (ENTRY_BYTES ÷ 8) * (TABLE_SIZE + 1))
    p = Ptr{UInt8}(pointer(data))
    pad = -Int(UInt(p)) & (ENTRY_BYTES - 1)
    return Table(data, p + pad, Ref(0))
end

# `cnt == 0` is the empty marker and an insert writes min and max outright, so
# zeroed memory is a valid empty table — there are no sentinels to fill in.
@inline entry(t::Table, idx::Int) = t.base + idx * ENTRY_BYTES
@inline ld(::Type{T}, e::Ptr{UInt8}, off::Int) where {T} = unsafe_load(Ptr{T}(e + off))
@inline st!(e::Ptr{UInt8}, off::Int, v::T) where {T} = unsafe_store!(Ptr{T}(e + off), v)

@noinline table_full() = error(
    "more than $MAX_ENTRIES distinct station names in one thread's table; " *
    "the challenge caps the station set at 10000, so either the input is out " *
    "of spec or TABLE_BITS (currently $TABLE_BITS) needs raising")

"""
    name_tail_eq(base, a, b, len) -> Bool

Compare two names of equal length `len > INLINE_KEY_BYTES` held at offsets `a`
and `b` in the mapping, skipping the first 16 bytes because the caller has
already compared those against the copy stored in the entry.  Reads up to 7
bytes past each name, which the caller's tail carve-out makes safe.
"""
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

"""
    update!(t, base, h, noff, nlen, k0, k1, v)

Insert or accumulate one row.  `k0` and `k1` are the name's first sixteen
bytes, already masked to its length, and they are compared against the copy
held in the entry — in the same cache line as the statistics, which the probe
has loaded anyway.  For a name of sixteen bytes or fewer that comparison is
exact, so the common path never touches the name bytes in the mapping a second
time.  Only a longer name falls through to `name_tail_eq`.

`scan_name` has already run the hash through `finalize_hash`, so the low bits
are safe to index on directly.
"""
@inline function update!(t::Table, base::Ptr{UInt8}, h::UInt64,
                         noff::Int, nlen::Int, k0::UInt64, k1::UInt64, v::Int64)
    len32 = Int32(nlen)
    idx = Int(h & TABLE_MASK)
    while true
        e = entry(t, idx)
        if ld(Int32, e, O_CNT) == 0
            # Only reached once per distinct station, so the bookkeeping costs
            # nothing per row.
            n = t.nlive[] + 1
            n > MAX_ENTRIES && table_full()
            t.nlive[] = n
            st!(e, O_HASH, h)
            st!(e, O_OFF, noff)
            st!(e, O_SUM, v)
            st!(e, O_KEY0, k0)
            st!(e, O_KEY1, k1)
            st!(e, O_MIN, Int32(v))
            st!(e, O_MAX, Int32(v))
            st!(e, O_CNT, Int32(1))
            st!(e, O_LEN, len32)
            return nothing
        elseif ld(UInt64, e, O_KEY0) == k0 && ld(UInt64, e, O_KEY1) == k1 &&
               ld(Int32, e, O_LEN) == len32 &&
               (nlen <= INLINE_KEY_BYTES ||
                (ld(UInt64, e, O_HASH) == h &&
                 name_tail_eq(base, ld(Int64, e, O_OFF), noff, nlen)))
            v < ld(Int32, e, O_MIN) && st!(e, O_MIN, Int32(v))
            v > ld(Int32, e, O_MAX) && st!(e, O_MAX, Int32(v))
            st!(e, O_SUM, ld(Int64, e, O_SUM) + v)
            st!(e, O_CNT, ld(Int32, e, O_CNT) + Int32(1))
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
            ld(Int32, e, O_CNT) == 0 && continue
            name = unsafe_string(base + ld(Int64, e, O_OFF), ld(Int32, e, O_LEN))
            s = Stat(ld(Int32, e, O_MIN), ld(Int32, e, O_MAX),
                     ld(Int64, e, O_SUM), ld(Int32, e, O_CNT))
            prev = get(out, name, nothing)
            out[name] = prev === nothing ? s : combine(prev, s)
        end
    end
    return out
end

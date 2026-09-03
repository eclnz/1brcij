# SWAR scanning and branchless parsing.
#
# Little-endian only: byte 0 in memory is the low byte of a loaded UInt64.
# Offsets are 0-based bytes from a Ptr{UInt8}, never the 1-based
# `unsafe_load(p, i)` form. Callers must allow an 8-byte overread from any
# offset touched here; `fast_region_end` carves a tail off the file so this
# holds without relying on mmap page padding.

const ONES  = 0x0101010101010101
const HIGHS = 0x8080808080808080
const SEMIS = 0x3b3b3b3b3b3b3b3b
const NEWLINE = 0x0a
const SEMICOLON = 0x3b

"""
    match_bytes(word, pattern) -> UInt64

Set 0x80 in each byte lane of `word` equal to `pattern`. `trailing_zeros(m) >> 3`
gives the index of the first match.
"""
@inline function match_bytes(word::UInt64, pattern::UInt64)
    x = word ⊻ pattern
    return (x - ONES) & ~x & HIGHS      # the borrow marks zero lanes
end

"""
    tail_mask(nbytes) -> UInt64

Mask keeping the low `nbytes` bytes. `nbytes == 0` shifts by 64, which Julia
defines as 0 (unlike C), so there is no special case.
"""
@inline tail_mask(nbytes::Int) = typemax(UInt64) >> (64 - 8 * nbytes)

const HASH_BASIS = 0xcbf29ce484222325
const HASH_PRIME = 0x00000100000001b3   # odd, so the multiply stays invertible

@inline mix(h::UInt64, w::UInt64) = (h ⊻ w) * HASH_PRIME

"""
    finalize_hash(h) -> UInt64

Fold the high bits down before indexing: a multiply diffuses poorly into the
low bits, which is where `TABLE_MASK` looks. Over 10 000 station names this
costs 0.05 probes per insert against 5.23 for the raw low bits.
"""
@inline finalize_hash(h::UInt64) = h ⊻ (h >> 29)

"""
    scan_name(base, pos) -> (hash, name_end, key0, key1)

Locate and hash the name in one pass. `key0`/`key1` are its first 16 bytes
masked to length, which is what the table compares against.

The one- and two-word cases are written out because they cover 95% of the
station set and avoid the loop's serial multiply chain.
"""
@inline function scan_name(base::Ptr{UInt8}, pos::Int)
    w0 = unsafe_load(Ptr{UInt64}(base + pos))
    m0 = match_bytes(w0, SEMIS)
    if m0 != 0                                    # 0..7 bytes
        n = trailing_zeros(m0) >> 3
        k0 = w0 & tail_mask(n)
        return finalize_hash(mix(HASH_BASIS, k0)), pos + n, k0, UInt64(0)
    end

    w1 = unsafe_load(Ptr{UInt64}(base + pos + 8))
    m1 = match_bytes(w1, SEMIS)
    if m1 != 0                                    # 8..15 bytes
        n = trailing_zeros(m1) >> 3
        k1 = w1 & tail_mask(n)
        return finalize_hash(mix(mix(HASH_BASIS, w0), k1)), pos + 8 + n, w0, k1
    end

    return scan_name_long(base, pos, w0, w1)
end

"""
    scan_name_long(base, pos, w0, w1) -> (hash, name_end, key0, key1)

Names of 16 bytes or more. `@noinline` keeps its loop out of the two paths above.
"""
@noinline function scan_name_long(base::Ptr{UInt8}, pos::Int, w0::UInt64, w1::UInt64)
    h = mix(mix(HASH_BASIS, w0), w1)
    p = pos + 16
    while true
        word = unsafe_load(Ptr{UInt64}(base + p))
        m = match_bytes(word, SEMIS)
        if m != 0
            n = trailing_zeros(m) >> 3
            h = mix(h, word & tail_mask(n))
            return finalize_hash(h), p + n, w0, w1
        end
        h = mix(h, word)
        p += 8
    end
end

# Int64 rather than UInt64 so the signed arithmetic below never hits a mixed
# signed/unsigned promotion.
const DOT_BITS   = 0x0000000010101000        # bit 4 of bytes 1, 2 and 3
const SIGN_BYTE  = Int64(0x00000000000000ff)
const DIGIT_MASK = Int64(0x0000000f000f0f00)
const DIGIT_MUL  = Int64(0x00000000640a0001) # 100<<24 | 10<<16 | 1
const ABS_MASK   = Int64(0x00000000000003ff)

"""
    parse_value(word) -> (tenths, nbytes)

Parse `-?d?d.d\\n` from one 8-byte load with no branches (the merykitty trick).
Returns tenths of a degree, and the bytes consumed so the next row starts at
`value_start + nbytes`.

`'.'` and `'-'` have bit 4 clear where digits have it set, which locates both
without comparing. Shifting by `28 - dot` aligns the digits into fixed
positions whatever the layout was, `DIGIT_MUL` then sums `100d₁ + 10d₂ + d₃` in
a single multiply, and `(v ⊻ signed) - signed` negates without a branch.
"""
@inline function parse_value(word::UInt64)
    w = reinterpret(Int64, word)
    dot = trailing_zeros(~word & DOT_BITS)                  # 12, 20 or 28
    signed = (reinterpret(Int64, ~word) << 59) >> 63        # -1 if '-', else 0
    design = ~(signed & SIGN_BYTE)                          # zeroes the '-' lane
    digits = ((w & design) << (28 - dot)) & DIGIT_MASK
    absval = ((digits * DIGIT_MUL) >>> 32) & ABS_MASK
    return (absval ⊻ signed) - signed, (dot >> 3) + 3
end

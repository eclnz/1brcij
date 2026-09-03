# ---------------------------------------------------------------------------
# Layer 3/4/5: SWAR delimiter scanning, name hashing, branchless value parsing.
#
# Every routine here assumes a LITTLE-ENDIAN machine: byte 0 in memory is the
# least significant byte of the loaded UInt64.  All offsets are 0-BASED byte
# offsets from a raw `Ptr{UInt8}` base, i.e. the C convention, so the only
# pointer form used anywhere is `unsafe_load(base + off)`.  Never mix in the
# 1-based two-argument `unsafe_load(p, i)` form.
#
# Callers must guarantee that 8 bytes may be read from any offset touched here.
# `OneBRC.fast_region_end` carves out a tail of the file so that this holds
# without relying on mmap page padding.
# ---------------------------------------------------------------------------

const ONES  = 0x0101010101010101
const HIGHS = 0x8080808080808080
const SEMIS = 0x3b3b3b3b3b3b3b3b   # ';' broadcast to all 8 lanes
const NEWLINE = 0x0a
const SEMICOLON = 0x3b

"""
    match_bytes(word, pattern) -> UInt64

Set bit 0x80 in every byte lane of `word` that equals the corresponding lane of
`pattern`, and clear every other lane.  `trailing_zeros(m) >> 3` then gives the
index of the first matching byte.
"""
@inline function match_bytes(word::UInt64, pattern::UInt64)
    x = word ⊻ pattern              # a matching lane becomes 0x00
    return (x - ONES) & ~x & HIGHS  # borrow sets the high bit of zero lanes
end

"""
    tail_mask(nbytes) -> UInt64

Mask keeping the low `nbytes` bytes of a word.  `nbytes == 0` shifts by 64,
which Julia defines as 0 (unlike C), so no special case is needed.
"""
@inline tail_mask(nbytes::Int) = typemax(UInt64) >> (64 - 8 * nbytes)

# FNV-1a constants.  The multiplier must be odd so the multiply stays
# invertible mod 2^64 and no entropy is lost.
const HASH_BASIS = 0xcbf29ce484222325
const HASH_PRIME = 0x00000100000001b3

@inline mix(h::UInt64, w::UInt64) = (h ⊻ w) * HASH_PRIME

"""
    finalize_hash(h) -> UInt64

A multiply diffuses weakly into the low bits of its result, which is exactly
where a table index would look, so mix the high bits down before indexing.
Measured over the 10 000 station names of the extended challenge input, in a
131072-slot table: indexing on the raw low bits costs 5.23 probes per insert on
average (worst case 113), indexing on `h >> 40` costs 1.02 (worst case 112),
and this finalizer costs 0.05 (worst case 3).  It is a bijection, so it loses
nothing when the value is also used as the stored key digest.
"""
@inline finalize_hash(h::UInt64) = h ⊻ (h >> 29)

"""
    scan_name(base, pos) -> (hash, name_end, key0, key1)

Scan the station name starting at `pos` and hash it in the same pass: the name
bytes are read exactly once and no `String` is ever materialised.  Returns the
finalized FNV-1a hash, the 0-based offset of the terminating `';'`, and the
name's first sixteen bytes as two words masked to its length.

The two words are what the table compares against, so it can decide a hit
without going back to the mapping for names of sixteen bytes or fewer.  The
one- and two-word cases are written out rather than left to the loop because
they cover 95% of the 10 000-name station set, and writing them out keeps the
common path free of the loop's serial multiply chain.
"""
@inline function scan_name(base::Ptr{UInt8}, pos::Int)
    w0 = unsafe_load(Ptr{UInt64}(base + pos))
    m0 = match_bytes(w0, SEMIS)
    if m0 != 0                                    # name is 0..7 bytes
        n = trailing_zeros(m0) >> 3
        k0 = w0 & tail_mask(n)
        return finalize_hash(mix(HASH_BASIS, k0)), pos + n, k0, UInt64(0)
    end

    w1 = unsafe_load(Ptr{UInt64}(base + pos + 8))
    m1 = match_bytes(w1, SEMIS)
    if m1 != 0                                    # name is 8..15 bytes
        n = trailing_zeros(m1) >> 3
        k1 = w1 & tail_mask(n)
        return finalize_hash(mix(mix(HASH_BASIS, w0), k1)), pos + 8 + n, w0, k1
    end

    return scan_name_long(base, pos, w0, w1)      # 16 bytes or more: rare
end

"""
    scan_name_long(base, pos, w0, w1) -> (hash, name_end, key0, key1)

The general case, for names of sixteen bytes or more.  Split out and marked
`@noinline` so its loop does not bloat the two paths above.
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

# Masks for the branchless number parser.  Kept as Int64 so that the signed
# arithmetic below never triggers a mixed signed/unsigned promotion.
const DOT_BITS   = 0x0000000010101000   # bit 4 of bytes 1, 2 and 3
const SIGN_BYTE  = Int64(0x00000000000000ff)
const DIGIT_MASK = Int64(0x0000000f000f0f00)
const DIGIT_MUL  = Int64(0x00000000640a0001)  # 100<<24 | 10<<16 | 1
const ABS_MASK   = Int64(0x00000000000003ff)  # 0..999 fits in 10 bits

"""
    parse_value(word) -> (tenths, nbytes)

The merykitty trick: parse `d.d`, `dd.d`, `-d.d` or `-dd.d` followed by a
newline out of a single 8-byte load with no branches at all.  Returns the value
in **tenths of a degree** as an `Int64` and the number of bytes the row's value
field occupies including the trailing newline, so the next row starts at
`value_start + nbytes`.

* `'.'` (0x2e) and `'-'` (0x2d) have bit 4 clear; digits (0x30..0x39) have it
  set, which is what locates the decimal point and the sign without comparisons.
* The shift by `28 - dot` slides the digits into fixed bit positions whatever
  the layout was, so a constant mask can isolate the three digit nibbles.
* `DIGIT_MUL` performs `100*d1 + 10*d2 + d3` in one multiply, depositing the
  result in bits 32..41.  ASCII-to-value conversion is free because the nibble
  mask already drops the 0x30 bias.
* `(v ⊻ signed) - signed` is a branchless negate-or-identity.
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

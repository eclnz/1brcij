# Scanning primitives and the branchless value parser.
#
# Little-endian only. Indices are 1-based into a `Vector{UInt8}`. Callers must
# allow an 8-byte overread from any index touched here; `fast_region_end` carves
# off a file tail so that holds.

const ONES  = 0x0101010101010101
const HIGHS = 0x8080808080808080
const SEMIS = 0x3b3b3b3b3b3b3b3b
const NEWLINE = 0x0a
const SEMICOLON = 0x3b

"""
    load8(data, i) -> UInt64

Little-endian 8-byte load. LLVM folds the shift-and-or chain back into a single
unaligned `mov`, so this is free — except in `finish_row!`, which says why.
"""
@inline function load8(data::Vector{UInt8}, i::Int)
    @inbounds return UInt64(data[i])      | UInt64(data[i + 1]) << 8  |
           UInt64(data[i + 2]) << 16 | UInt64(data[i + 3]) << 24 |
           UInt64(data[i + 4]) << 32 | UInt64(data[i + 5]) << 40 |
           UInt64(data[i + 6]) << 48 | UInt64(data[i + 7]) << 56
end

"""
    match16(a, b, c) -> UInt32

Bytewise compare of two words against `c`, as a 16-bit mask. Julia has no
portable spelling for `vpcmpeqb`, hence the IR. Taking the words by value rather
than by address keeps it off raw pointers: the caller has loaded them anyway.
"""
@inline function match16(a::UInt64, b::UInt64, c::UInt8)
    Base.llvmcall(("""
        define i32 @entry(i64 %a, i64 %b, i8 %c) #0 {
            %p0 = insertelement <2 x i64> undef, i64 %a, i32 0
            %p1 = insertelement <2 x i64> %p0, i64 %b, i32 1
            %v  = bitcast <2 x i64> %p1 to <16 x i8>
            %s0 = insertelement <16 x i8> undef, i8 %c, i32 0
            %sp = shufflevector <16 x i8> %s0, <16 x i8> undef, <16 x i32> zeroinitializer
            %e  = icmp eq <16 x i8> %v, %sp
            %m  = bitcast <16 x i1> %e to i16
            %r  = zext i16 %m to i32
            ret i32 %r
        }
        attributes #0 = { alwaysinline }
        """, "entry"), UInt32, Tuple{UInt64, UInt64, UInt8}, a, b, c)
end

"""Set 0x80 in each byte lane of `word` equal to `pattern`."""
@inline function match_bytes(word::UInt64, pattern::UInt64)
    x = word ⊻ pattern
    return (x - ONES) & ~x & HIGHS      # the borrow marks zero lanes
end

"""Mask keeping the low `nbytes` bytes. A 64-bit shift is 0 in Julia, unlike C."""
@inline tail_mask(nbytes::Int) = typemax(UInt64) >> (64 - 8 * nbytes)

"""A located name: its hash, the index of its `';'`, and its first 16 bytes."""
struct Name
    hash::UInt64
    stop::Int
    key0::UInt64
    key1::UInt64
end

const HASH_BASIS = 0xcbf29ce484222325
const HASH_PRIME = 0x00000100000001b3   # odd, so the multiply stays invertible

@inline mix(h::UInt64, w::UInt64) = (h ⊻ w) * HASH_PRIME

# A multiply diffuses poorly into its low bits, which is where TABLE_MASK looks.
# Across 10 000 names: 0.05 probes per insert with this, 5.23 without.
@inline finalize_hash(h::UInt64) = h ⊻ (h >> 29)

"""
    scan_name(data, pos) -> Name

Locate and hash the name in one pass. One vector compare covers any name under
16 bytes, which is 95% of the station set; the key masking is branchless.
"""
@inline function scan_name(data::Vector{UInt8}, pos::Int)
    w0 = load8(data, pos)
    w1 = load8(data, pos + 8)
    m = match16(w0, w1, SEMICOLON)
    if m != 0
        n = Int(trailing_zeros(m))
        k0 = w0 & tail_mask(ifelse(n > 8, 8, n))
        k1 = w1 & tail_mask(ifelse(n > 8, n - 8, 0))
        return Name(finalize_hash(mix(mix(HASH_BASIS, k0), k1)), pos + n, k0, k1)
    end
    return scan_name_long(data, pos, w0, w1)
end

"""Names of 16 bytes or more. `@noinline` keeps the loop out of the path above."""
@noinline function scan_name_long(data::Vector{UInt8}, pos::Int, w0::UInt64, w1::UInt64)
    h = mix(mix(HASH_BASIS, w0), w1)
    p = pos + 16
    while true
        word = load8(data, p)
        m = match_bytes(word, SEMIS)
        if m != 0
            n = trailing_zeros(m) >> 3
            h = mix(h, word & tail_mask(n))
            return Name(finalize_hash(h), p + n, w0, w1)
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

Parse `-?d?d.d\\n` from one 8-byte load with no branches (the merykitty trick),
returning tenths and the bytes consumed.

`'.'` and `'-'` have bit 4 clear where digits have it set, which locates both
without comparing. The shift by `28 - dot` aligns the digits whatever the
layout, `DIGIT_MUL` sums `100d₁ + 10d₂ + d₃` in one multiply, and
`(v ⊻ signed) - signed` negates without a branch.
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

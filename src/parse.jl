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
    match16(p, c) -> UInt32

Bytewise compare of the 16 bytes at `p` against `c`, as a 16-bit mask. One
`vpcmpeqb` where the SWAR path needs two word-at-a-time sequences.
"""
@inline function match16(p::Ptr{UInt8}, c::UInt8)
    Base.llvmcall(("""
        define i32 @entry(i64 %p, i8 %c) #0 {
            %ptr = inttoptr i64 %p to ptr
            %v = load <16 x i8>, ptr %ptr, align 1
            %s0 = insertelement <16 x i8> undef, i8 %c, i32 0
            %sp = shufflevector <16 x i8> %s0, <16 x i8> undef, <16 x i32> zeroinitializer
            %e = icmp eq <16 x i8> %v, %sp
            %m = bitcast <16 x i1> %e to i16
            %r = zext i16 %m to i32
            ret i32 %r
        }
        attributes #0 = { alwaysinline }
        """, "entry"), UInt32, Tuple{UInt64, UInt8}, UInt64(p), c)
end

"""
    eq2x64(p, a, b) -> Bool

Are the two 64-bit words at `p` equal to `a` and `b`? One vector compare
instead of two scalar ones.
"""
@inline function eq2x64(p::Ptr{UInt8}, a::UInt64, b::UInt64)
    Base.llvmcall(("""
        define i8 @entry(i64 %p, i64 %a, i64 %b) #0 {
            %ptr = inttoptr i64 %p to ptr
            %v = load <2 x i64>, ptr %ptr, align 8
            %k0 = insertelement <2 x i64> undef, i64 %a, i32 0
            %k1 = insertelement <2 x i64> %k0, i64 %b, i32 1
            %e = icmp eq <2 x i64> %v, %k1
            %m = bitcast <2 x i1> %e to i2
            %f = icmp eq i2 %m, 3
            %r = zext i1 %f to i8
            ret i8 %r
        }
        attributes #0 = { alwaysinline }
        """, "entry"), Bool, Tuple{UInt64, UInt64, UInt64}, UInt64(p), a, b)
end


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

One 16-byte vector compare finds the delimiter for any name under 16 bytes,
which is 95% of the station set, and the masking is branchless from there.
"""
@inline function scan_name(base::Ptr{UInt8}, pos::Int)
    m = match16(base + pos, SEMICOLON)
    w0 = unsafe_load(Ptr{UInt64}(base + pos))
    w1 = unsafe_load(Ptr{UInt64}(base + pos + 8))
    if m != 0
        n = Int(trailing_zeros(m))
        k0 = w0 & tail_mask(ifelse(n > 8, 8, n))
        k1 = w1 & tail_mask(ifelse(n > 8, n - 8, 0))
        return finalize_hash(mix(mix(HASH_BASIS, k0), k1)), pos + n, k0, k1
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

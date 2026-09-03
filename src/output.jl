# Aggregation is integer tenths throughout; floating point enters only here.

"""Mean in tenths, half-up to match Java's `Math.round`; Julia's rounds to even."""
@inline round_tenths(sum::Integer, cnt::Integer) =
    Int64(floor(Float64(sum) / Float64(cnt) + 0.5))

"""Render tenths with exactly one fractional digit."""
function fmt_tenths(t::Integer)
    a = abs(Int64(t))
    s = string(a ÷ 10, '.', a % 10)
    return t < 0 ? '-' * s : s
end

"""
    format_result(stats) -> String

The challenge's `{Abha=-23.0/18.0/59.2, ...}` line, sorted by name. Julia orders
`String`s by UTF-8 bytes, which matches code point order for every station here.
"""
function format_result(stats::AbstractDict{String,Stat})
    names = sort!(collect(keys(stats)))
    io = IOBuffer()
    print(io, '{')
    for (i, name) in enumerate(names)
        s = stats[name]
        i == 1 || print(io, ", ")
        print(io, name, '=', fmt_tenths(s.min), '/',
              fmt_tenths(round_tenths(s.sum, s.cnt)), '/', fmt_tenths(s.max))
    end
    print(io, '}')
    return String(take!(io))
end

# The obviously-correct oracle the fast path is diffed against, plus the
# byte-at-a-time parser for the carved-out file tail (see `fast_region_end`).

"""
    parse_tenths(s) -> Int64

Parse a temperature into tenths, assuming nothing about its layout.
Deliberately unrelated to `parse_value` so it is an independent check on it.
"""
function parse_tenths(s::AbstractString)
    return round(Int64, parse(Float64, s) * 10)
end

"""
    baseline(path) -> Dict{String,Stat}

One `String` per line, two `SubString`s per row, a generic float parse. Minutes
on the full file, and the oracle everything else is checked against.
"""
function baseline(path::AbstractString)
    stats = Dict{String,Stat}()
    for line in eachline(path)
        isempty(line) && continue
        i = findfirst(==(';'), line)
        i === nothing && continue
        name = line[1:prevind(line, i)]
        v = parse_tenths(line[nextind(line, i):end])
        prev = get(stats, name, nothing)
        s = Stat(v, v, v, 1)
        stats[name] = prev === nothing ? s : combine(prev, s)
    end
    return stats
end

"""
    accumulate_slow!(stats, data, from, to)

Accumulate rows in the 0-based byte range `[from, to)` with no wide loads, so it
is safe against the end of the mapping. Only the last few thousand rows.
"""
function accumulate_slow!(stats::Dict{String,Stat}, data::Vector{UInt8},
                          from::Int, to::Int)
    pos = from
    @inbounds while pos < to
        semi = pos
        while semi < to && data[semi + 1] != SEMICOLON
            semi += 1
        end
        semi >= to && break
        eol = semi + 1
        while eol < to && data[eol + 1] != NEWLINE
            eol += 1
        end
        name = String(@view data[(pos + 1):semi])
        v = parse_tenths(String(@view data[(semi + 2):eol]))
        prev = get(stats, name, nothing)
        s = Stat(v, v, v, 1)
        stats[name] = prev === nothing ? s : combine(prev, s)
        pos = eol + 1
    end
    return stats
end

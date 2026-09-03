# Mirrors the reference generator: a station drawn uniformly, its temperature
# normal around that station's mean with sd 10.

struct Station
    name::String
    mean::Float64
end

stations_path() = joinpath(dirname(@__DIR__), "data", "stations.csv")

"""Read a `<name>;<mean temperature>` list, skipping `#` comments."""
function load_stations(path::AbstractString = stations_path())
    out = Station[]
    for line in eachline(path)
        (isempty(line) || startswith(line, '#')) && continue
        i = findfirst(==(';'), line)
        i === nothing && continue
        push!(out, Station(line[1:prevind(line, i)],
                           parse(Float64, line[nextind(line, i):end])))
    end
    return out
end

@inline function write_tenths(io::IO, t::Int)
    t < 0 && write(io, UInt8('-'))
    a = abs(t)
    q, r = divrem(a, 10)
    if q >= 10
        write(io, UInt8('0') + UInt8(q ÷ 10))
    end
    write(io, UInt8('0') + UInt8(q % 10), UInt8('.'), UInt8('0') + UInt8(r))
    return nothing
end

"""
    generate(path, nrows; seed, stations) -> path

Write `nrows` rows. Temperatures are clamped to `-99.9 .. 99.9` so the file
always satisfies the parser's assumptions.
"""
function generate(path::AbstractString, nrows::Integer;
                  seed::Integer = 20240101,
                  stations::Vector{Station} = load_stations())
    isempty(stations) && error("no stations to generate from")
    names = [Vector{UInt8}(codeunits(s.name)) for s in stations]
    means = [s.mean for s in stations]
    n = length(names)
    rng = Random.Xoshiro(seed)
    open(path, "w") do io
        buf = IOBuffer()
        for _ in 1:nrows
            k = rand(rng, 1:n)
            t = clamp(round(Int, (means[k] + randn(rng) * 10.0) * 10.0), -999, 999)
            write(buf, names[k])
            write(buf, SEMICOLON)
            write_tenths(buf, t)
            write(buf, NEWLINE)
            if position(buf) >= (1 << 20)
                write(io, take!(buf))
            end
        end
        write(io, take!(buf))
    end
    return path
end

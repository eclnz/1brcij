using Test
include(joinpath(@__DIR__, "..", "src", "OneBRC.jl"))
using .OneBRC
using Random
using .OneBRC: match_bytes, tail_mask, scan_name, parse_value, parse_tenths,
               Table, update!, merge_tables, Stat, combine, name_tail_eq, Name,
               fmt_tenths, round_tenths, format_result, fast_region_end,
               next_row_start, segment_start, SEGMENT_SIZE, TAIL_SLACK,
               accumulate_slow!, load_stations, generate, run_file

const SCRATCH = mktempdir()
const SAMPLES = joinpath(@__DIR__, "samples")

@testset "OneBRC" begin

@testset "shift semantics" begin
    # tail_mask leans on Julia defining an over-shift as zero, not UB.
    @test typemax(UInt64) >> 64 === UInt64(0)
    @test tail_mask(0) === UInt64(0)
    @test tail_mask(1) === 0x00000000000000ff
    @test tail_mask(7) === 0x00ffffffffffffff
    @test tail_mask(8) === typemax(UInt64)
end

@testset "SWAR byte matching" begin
    for i in 0:7
        w = UInt64(0x3b) << (8 * i)          # a ';' in lane i, zeros elsewhere
        m = match_bytes(w, OneBRC.SEMIS)
        @test m != 0
        @test trailing_zeros(m) >> 3 == i
    end
    # 0x00 lanes are not ';', and high-bit bytes are not false positives.
    @test match_bytes(0x0000000000000000, OneBRC.SEMIS) == 0
    @test match_bytes(0xffffffffffffffff, OneBRC.SEMIS) == 0
    @test match_bytes(0x8080803b80808080, OneBRC.SEMIS) != 0
    @test trailing_zeros(match_bytes(0x8080803b80808080, OneBRC.SEMIS)) >> 3 == 4
    # first match wins when there are several
    @test trailing_zeros(match_bytes(0x3b0000003b000000, OneBRC.SEMIS)) >> 3 == 3
end

@testset "branchless value parsing" begin
    # Exhaustive over the documented range, in every layout, with junk in the
    # trailing bytes to prove they are ignored.
    for tenths in -999:999
        s = OneBRC.fmt_tenths(tenths) * "\n"
        for junk in ("", "Abha;12.3\n", "\xff\xff\xff\xff\xff\xff\xff\xff")
            bytes = Vector{UInt8}(codeunits(s * junk))
            append!(bytes, zeros(UInt8, 16))
            word = GC.@preserve bytes unsafe_load(Ptr{UInt64}(pointer(bytes)))
            v, adv = parse_value(word)
            @test v == tenths
            @test adv == length(codeunits(s))
            @test v == parse_tenths(strip(s))
        end
    end
end

@testset "name scanning and hashing" begin
    for name in ["A", "Abha", "Abidjan", "Abéché", "Ürümqi", "Kuala Lumpur",
                 "Cracow", "San Juan", "12345678", "1234567", "123456789",
                 "Alexandra", "Alexandria", repeat("x", 99)]
        buf = Vector{UInt8}(codeunits(name * ";12.3\n"))
        append!(buf, zeros(UInt8, 16))
        nm = GC.@preserve buf scan_name(pointer(buf), 0)
        h, nend, k0, k1 = nm.hash, nm.stop, nm.key0, nm.key1
        @test nend == length(codeunits(name))
        # the inline key must be the name's first 16 bytes, masked to length
        raw = Vector{UInt8}(codeunits(name)); append!(raw, zeros(UInt8, 16))
        want0 = GC.@preserve raw unsafe_load(Ptr{UInt64}(pointer(raw)))
        want1 = GC.@preserve raw unsafe_load(Ptr{UInt64}(pointer(raw) + 8))
        n = length(codeunits(name))
        @test k0 == (n >= 8 ? want0 : want0 & OneBRC.tail_mask(n))
        @test k1 == (n >= 16 ? want1 : n <= 8 ? UInt64(0) :
                     want1 & OneBRC.tail_mask(n - 8))
        # the hash must depend only on the name, not on what follows it
        buf2 = Vector{UInt8}(codeunits(name * ";-45.6\nZagreb;1.0\n"))
        append!(buf2, zeros(UInt8, 16))
        nm2 = GC.@preserve buf2 scan_name(pointer(buf2), 0)
        @test nm == nm2
    end
    # distinct names, distinct hashes, over the real station list
    names = [s.name for s in load_stations()]
    hs = map(names) do name
        buf = Vector{UInt8}(codeunits(name * ";0.0\n")); append!(buf, zeros(UInt8, 16))
        GC.@preserve buf scan_name(pointer(buf), 0).hash
    end
    @test length(unique(hs)) == length(names)
    # Collisions are expected and handled by probing; only a lot of them would
    # mean the hash is at fault. The birthday bound predicts ~2.6 here.
    slots = [Int(h & OneBRC.TABLE_MASK) for h in hs]
    @test length(names) - length(unique(slots)) <= 12
end

@testset "probe distance at the 10 000 station limit" begin
    # A weak index is a silent performance leak rather than a bug, so measure
    # it at the challenge's 10 000-name cap.
    rng = Random.Xoshiro(7)
    alphabet = collect("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ -")
    names = Set{String}()
    while length(names) < 10_000
        push!(names, String(rand(rng, alphabet, rand(rng, 3:24))))
    end
    occupied = falses(OneBRC.TABLE_SIZE)
    total, worst = 0, 0
    for name in names
        buf = Vector{UInt8}(codeunits(name * ";0.0\n")); append!(buf, zeros(UInt8, 16))
        h = GC.@preserve buf scan_name(pointer(buf), 0).hash
        i = Int(h & OneBRC.TABLE_MASK) + 1
        d = 0
        while occupied[i]
            i = i == OneBRC.TABLE_SIZE ? 1 : i + 1
            d += 1
        end
        occupied[i] = true
        total += d
        worst = max(worst, d)
    end
    # Measured 0.235 average, 3..8 worst at TABLE_BITS = 15. Loose enough for a
    # different random name set, tight enough to catch a hash gone bad.
    @test total / length(names) < 0.5
    @test worst < 24
end

@testset "name comparison beyond the inline key" begin
    # name_tail_eq starts at byte 16; the first 16 are the entry's inline key.
    long1 = "Alexandria-on-the-Sea"        # 21 bytes, shares its first 16
    long2 = "Alexandria-on-the-Bay"        # 21 bytes, differs at byte 19
    a = Vector{UInt8}(codeunits(long1 * "\n" * long2 * "\n" * long1 * "\n"))
    append!(a, zeros(UInt8, 16))
    n = ncodeunits(long1)
    GC.@preserve a begin
        p = pointer(a)
        @test name_tail_eq(p, 0, 2n + 2, n)      # long1 vs long1
        @test !name_tail_eq(p, 0, n + 1, n)      # long1 vs long2
        @test name_tail_eq(p, n + 1, n + 1, n)   # reflexive
    end
end

@testset "rounding and formatting" begin
    @test fmt_tenths(0) == "0.0"
    @test fmt_tenths(-1) == "-0.1"
    @test fmt_tenths(999) == "99.9"
    @test fmt_tenths(-999) == "-99.9"
    @test fmt_tenths(180) == "18.0"
    # half-up towards +inf, i.e. Math.round, NOT banker's rounding
    @test round_tenths(5, 2) == 3          # 2.5 -> 3, Julia's round gives 2
    @test round_tenths(15, 2) == 8         # 7.5 -> 8
    @test round_tenths(-5, 2) == -2        # -2.5 -> -2
    @test round_tenths(-15, 2) == -7       # -7.5 -> -7
    @test round_tenths(7, 2) == 4
    stats = Dict("Abha" => Stat(-230, 592, 180, 1),
                 "Abidjan" => Stat(10, 20, 30, 2))
    @test format_result(stats) == "{Abha=-23.0/18.0/59.2, Abidjan=1.0/1.5/2.0}"
end

@testset "segmentation" begin
    text = join(["st$i;$(i % 10).$(i % 10)" for i in 1:5000], "\n") * "\n"
    buf = Vector{UInt8}(codeunits(text)); append!(buf, zeros(UInt8, 16))
    n = length(codeunits(text))
    GC.@preserve buf begin
        p = pointer(buf)
        @test segment_start(p, 1, n) == 0
        # every segment boundary must land immediately after a newline
        for seg in 2:10
            s = segment_start(p, seg, n)
            @test s == n || (s > 0 && buf[s] == UInt8('\n'))
        end
        @test next_row_start(p, 0, n) == findfirst(==(UInt8('\n')), buf)
        @test next_row_start(p, n - 1, n) == n
    end
end

@testset "fast/slow region split" begin
    small = Vector{UInt8}(codeunits("a;1.0\n"))
    @test fast_region_end(small, length(small)) == 0    # everything is tail
    big = Vector{UInt8}(codeunits(repeat("station;12.3\n", 20_000)))
    n = length(big)
    fend = fast_region_end(big, n)
    @test 0 < fend <= n - TAIL_SLACK + OneBRC.MAX_ROW_BYTES
    @test big[fend] == UInt8('\n')                       # lands on a row boundary
end

@testset "end to end against the reference" begin
    # Repeated names, both signs, all four value layouts, non-ASCII, extremes.
    rows = String[]
    for (name, v) in [("Abha", "-23.0"), ("Abha", "59.2"), ("Abidjan", "0.0"),
                      ("Abéché", "-0.1"), ("Ürümqi", "99.9"), ("Ürümqi", "-99.9"),
                      ("A", "1.2"), ("A", "-1.2"), ("12345678", "12.3"),
                      ("Kuala Lumpur", "-9.9"), ("Abha", "18.0")]
        push!(rows, "$name;$v")
    end
    path = joinpath(SCRATCH, "tiny.txt")
    write(path, join(rows, "\n") * "\n")
    @test format_result(run_file(path)) == format_result(baseline(path))
    @test run_file(path)["Abha"] == Stat(-230, 592, -230 + 592 + 180, 3)

    # No trailing newline on the last row.
    path2 = joinpath(SCRATCH, "no_trailing_newline.txt")
    write(path2, join(rows, "\n"))
    @test format_result(run_file(path2)) == format_result(baseline(path2))

    # Single row, and an empty file.
    path3 = joinpath(SCRATCH, "one.txt")
    write(path3, "Abha;-1.0\n")
    @test format_result(run_file(path3)) == "{Abha=-1.0/-1.0/-1.0}"
    path4 = joinpath(SCRATCH, "empty.txt")
    write(path4, "")
    @test format_result(run_file(path4)) == "{}"
end

@testset "generated file matches the reference" begin
    for (rows, seed) in [(10_000, 1), (250_000, 2)]
        path = joinpath(SCRATCH, "gen_$(rows).txt")
        generate(path, rows; seed = seed)
        @test format_result(run_file(path)) == format_result(baseline(path))
    end
end

@testset "file larger than one segment" begin
    # Forces real segmentation, multiple threads and the ILP cursor split.
    path = joinpath(SCRATCH, "multi_segment.txt")
    generate(path, 900_000; seed = 3)
    @test filesize(path) > 3 * SEGMENT_SIZE
    fast = run_file(path)
    slow = baseline(path)
    @test format_result(fast) == format_result(slow)
    @test sum(s.cnt for s in values(fast)) == 900_000
end

@testset "table overflow fails loudly instead of hanging" begin
    # A full table would send the probe loop round forever: a hang, not a wrong
    # answer. Driven through update! directly because each thread owns a table
    # and sees only its own segments, so a threaded run would never fill one.
    function fill_table(n)
        io = IOBuffer()
        for i in 1:n
            print(io, "station", lpad(i, 7, '0'), ";1.0\n")
        end
        buf = take!(io)
        append!(buf, zeros(UInt8, 16))
        tbl = Table()
        GC.@preserve buf begin
            p = pointer(buf)
            pos = 0
            for _ in 1:n
                nm = scan_name(p, pos)
                update!(tbl, p, pos, nm, Int64(10))
                pos = nm.stop + 6         # ";1.0\n"
            end
        end
        return tbl
    end

    @test fill_table(OneBRC.MAX_ENTRIES).nlive[] == OneBRC.MAX_ENTRIES
    @test_throws ErrorException fill_table(OneBRC.MAX_ENTRIES + 1)
    # The cap must leave room for the station set the challenge permits.
    @test OneBRC.MAX_ENTRIES >= 10_000
end

@testset "the safe implementation agrees with the unsafe one" begin
    # OneBRC.Safe reimplements the pipeline without pointers, llvmcall or
    # @inbounds. It exists to be measured against, so it has to stay correct.
    for sample in sort(filter(f -> endswith(f, ".txt"), readdir(SAMPLES; join = true)))
        @test format_result(run_file(sample)) ==
              format_result(OneBRC.Safe.run_file(sample))
    end
    path = joinpath(SCRATCH, "safe_gen.txt")
    generate(path, 300_000; seed = 12)
    @test format_result(run_file(path)) == format_result(OneBRC.Safe.run_file(path))
end

@testset "the hot path does not allocate" begin
    path = joinpath(SCRATCH, "alloc.txt")
    generate(path, 200_000; seed = 4)
    data = read(path)
    append!(data, zeros(UInt8, 64))
    n = something(findlast(==(UInt8('\n')), data))
    tbl = Table()
    GC.@preserve data begin
        p = pointer(data)
        OneBRC.process_segment!(tbl, p, 0, n)          # warm up / compile
        tbl2 = Table()
        allocated = @allocated OneBRC.process_segment!(tbl2, p, 0, n)
        @test allocated == 0
    end
end

end

rm(SCRATCH; recursive = true, force = true)

#!/usr/bin/env julia
# usage: julia --project probe_many.jl <scenario> <cohortdir>
#
# The 100-separate-images counterpart to probe.jl. Same counters, same
# cold-cache discipline; the unit of work is "read one voxel from each of N
# images", which is the shape of a group analysis at a single coordinate.

using NIfTI, Random, Mmap

include(joinpath(@__DIR__, "counters.jl"))

images(dir) = sort(joinpath.(dir, filter(f -> endswith(f, ".nii") && f != "tiny.nii",
                                         readdir(dir))))

"""A deterministic voxel, drawn against the volume's own bounds."""
pick(rng, v) = ntuple(d -> rand(rng, 1:size(v, d)), 3)

function eager(paths)
    rng = MersenneTwister(11)
    return sum(begin v = niread(p); v[pick(rng, v)...] end for p in paths)
end

function mapped(paths; advise = nothing)
    rng = MersenneTwister(11)
    acc = 0.0
    for p in paths
        v = niread(p; mmap = true)
        advise === nothing || Mmap.madvise!(v.raw, advise)
        acc += v[pick(rng, v)...]
    end
    return acc
end

"""Hold every mapping open at once, so descriptors and VMAs accumulate."""
function mapped_held(paths; advise = nothing)
    rng = MersenneTwister(11)
    held = Vector{Any}(undef, length(paths))
    acc = 0.0
    for (i, p) in enumerate(paths)
        v = niread(p; mmap = true)
        advise === nothing || Mmap.madvise!(v.raw, advise)
        held[i] = v
        acc += v[pick(rng, v)...]
    end
    println(stderr, "  open fds while holding ", length(paths), " mappings: ", nopenfds())
    return acc + 0 * length(held)
end

"""As `mapped_held`, but collecting every `every` images so the finalizers that
close NIfTI.jl's streams actually run."""
function mapped_held_gc(paths; advise = nothing, every = 25)
    rng = MersenneTwister(11)
    held = Vector{Any}(undef, length(paths))
    acc = 0.0
    for (i, p) in enumerate(paths)
        v = niread(p; mmap = true)
        advise === nothing || Mmap.madvise!(v.raw, advise)
        held[i] = v
        acc += v[pick(rng, v)...]
        i % every == 0 && GC.gc()
    end
    println(stderr, "  open fds while holding ", length(paths), " mappings: ", nopenfds())
    return acc + 0 * length(held)
end

const SCENARIOS = Dict{String,Function}(
    "many_eager"      => eager,
    "many_mmap"       => paths -> mapped(paths),
    "many_mmap_rand"  => paths -> mapped(paths; advise = Mmap.MADV_RANDOM),
    "many_mmap_held"  => paths -> mapped_held(paths; advise = Mmap.MADV_RANDOM),
    "many_mmap_gc"    => paths -> mapped_held_gc(paths; advise = Mmap.MADV_RANDOM),
)

function main(args)
    length(args) == 2 || (println(stderr, "usage: probe_many.jl <scenario> <cohortdir>"); return 2)
    name, dir = args
    haskey(SCENARIOS, name) || (println(stderr, "unknown scenario: ", name); return 2)
    f = SCENARIOS[name]
    paths = images(dir)

    f([joinpath(dir, "tiny.nii")])              # compile
    GC.gc(); GC.gc()

    drop_caches()
    io0, r0, m0, fd0 = iocounters(), rss(), majflt(), nopenfds()
    t = @elapsed result = f(paths)
    io1, r1, m1, fd1 = iocounters(), rss(), majflt(), nopenfds()

    total = sum(filesize, paths)
    println(join((name, length(paths), total, round(t; digits = 4),
                  io1.rchar - io0.rchar, io1.read_bytes - io0.read_bytes,
                  r1 - r0, m1 - m0, fd1 - fd0, result), '\t'))
    return 0
end

exit(main(ARGS))

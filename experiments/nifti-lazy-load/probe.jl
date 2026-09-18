#!/usr/bin/env julia
# usage: julia --project probe.jl <scenario> <datadir>
#
# Runs exactly one scenario in a fresh process and prints one TSV line of
# kernel-observed counters. Fresh process per scenario is the point: RSS and
# the /proc/self/io counters are process-wide and monotonic, so two scenarios
# in one process cannot be told apart.
#
# What the counters mean here:
#
#   rchar       bytes delivered to read()/pread() syscalls. Page faults against
#               an mmap do NOT count, so this is "how much did the library pull
#               through the read path", i.e. eager loading.
#   read_bytes  bytes actually fetched from the block device. Counts both read()
#               and major faults, so this is real disk traffic.
#   rss         resident set size. For an mmap this is "how much of the array is
#               actually in this process right now".
#   majflt      major (disk-backed) page faults.
#
# The page cache is dropped between warmup and measurement, so read_bytes and
# the wall time describe a cold read.

using NIfTI, Random, Mmap

const PAGE = 4096

function iocounters()
    rchar = readb = 0
    for line in eachline("/proc/self/io")
        k, _, v = partition(line)
        k == "rchar" && (rchar = v)
        k == "read_bytes" && (readb = v)
    end
    return (rchar = rchar, read_bytes = readb)
end

function partition(line)
    i = findfirst(==(':'), line)
    i === nothing && return ("", "", 0)
    return (line[1:i-1], ":", parse(Int, strip(line[i+1:end])))
end

rss() = parse(Int, split(read("/proc/self/statm", String))[2]) * PAGE

function majflt()
    s = read("/proc/self/stat", String)
    fields = split(s[findlast(==(')'), s)+2:end])
    return parse(Int, fields[10])   # majflt, shifted by the two fields before comm
end

function drop_caches()
    run(`sync`)
    write("/proc/sys/vm/drop_caches", "3")
    return nothing
end

# ---------------------------------------------------------------- scenarios
#
# Each scenario is (file key, closure). The closure runs once on the tiny file
# to force compilation, then once on the real file under measurement. It
# returns a value that is kept alive and checksummed so nothing is optimised
# away.

"""Deterministic voxel coordinates, scattered so they land on distinct pages."""
function probe_coords(dims, n; seed = 7)
    rng = MersenneTwister(seed)
    return [ntuple(d -> rand(rng, 1:dims[d]), length(dims)) for _ in 1:n]
end

const NVOX = 64

read_scattered(v, n) = sum(v[c...] for c in probe_coords(size(v), n))

const SCENARIOS = Dict{String,Tuple{String,Function}}(
    # Baseline: what the package does by default.
    "eager_open"       => ("fmri.nii", p -> sum(niread(p).raw[1, 1, 1, 1])),
    "eager_voxels"     => ("fmri.nii", p -> read_scattered(niread(p), NVOX)),
    "eager_sumall"     => ("fmri.nii", p -> sum(niread(p).raw)),

    # The claim under test.
    "mmap_open"        => ("fmri.nii", p -> sum(niread(p; mmap = true).raw[1, 1, 1, 1])),
    "mmap_voxels"      => ("fmri.nii", p -> read_scattered(niread(p; mmap = true), NVOX)),
    "mmap_timeseries"  => ("fmri.nii", p -> begin
                               v = niread(p; mmap = true)
                               nx, ny, nz, _ = size(v)
                               sum(v.raw[nx ÷ 2, ny ÷ 2, nz ÷ 2, :])
                           end),
    "mmap_oneslice"    => ("fmri.nii", p -> begin
                               v = niread(p; mmap = true)
                               sum(v.raw[:, :, size(v, 3) ÷ 2, 1])
                           end),
    "mmap_onevolume"   => ("fmri.nii", p -> sum(niread(p; mmap = true).raw[:, :, :, 1])),
    "mmap_sumall"      => ("fmri.nii", p -> sum(niread(p; mmap = true).raw)),

    # Same two access patterns, but telling the kernel not to read ahead. The
    # gap between these and the pair above is the readahead window, not NIfTI.jl.
    "mmap_voxels_rand" => ("fmri.nii", p -> begin
                               v = niread(p; mmap = true)
                               Mmap.madvise!(v.raw, Mmap.MADV_RANDOM)
                               read_scattered(v, NVOX)
                           end),
    "mmap_tseries_rand" => ("fmri.nii", p -> begin
                               v = niread(p; mmap = true)
                               Mmap.madvise!(v.raw, Mmap.MADV_RANDOM)
                               nx, ny, nz, _ = size(v)
                               sum(v.raw[nx ÷ 2, ny ÷ 2, nz ÷ 2, :])
                           end),

    # Gzipped input.
    "gz_eager_voxels"  => ("fmri.nii.gz", p -> read_scattered(niread(p), NVOX)),
    "gz_mmap_open"     => ("fmri.nii.gz", p -> try
                               sum(niread(p; mmap = true).raw[1, 1, 1, 1])
                           catch err
                               println(stderr, "  gz mmap raised: ", sprint(showerror, err))
                               -1.0
                           end),

    # Byte-swapped input goes through a MappedArray wrapper; is it still lazy?
    "be_mmap_voxels"   => ("anat_be.nii", p -> read_scattered(niread(p; mmap = true), NVOX)),
    "le_mmap_voxels"   => ("anat.nii", p -> read_scattered(niread(p; mmap = true), NVOX)),
    "be_eager_voxels"  => ("anat_be.nii", p -> read_scattered(niread(p), NVOX)),
)

tiny_for(file) =
    file == "fmri.nii"    ? "tiny_fmri.nii" :
    file == "fmri.nii.gz" ? "tiny_fmri.nii.gz" :
    file == "anat_be.nii" ? "tiny_anat_be.nii" : "tiny_anat.nii"

function main(args)
    length(args) == 2 || (println(stderr, "usage: probe.jl <scenario> <datadir>"); return 2)
    name, dir = args
    haskey(SCENARIOS, name) || (println(stderr, "unknown scenario: ", name); return 2)
    file, f = SCENARIOS[name]

    warm = f(joinpath(dir, tiny_for(file)))     # compile everything
    warm === nothing && return 3
    GC.gc(); GC.gc()

    drop_caches()
    io0, r0, m0 = iocounters(), rss(), majflt()
    t = @elapsed result = f(joinpath(dir, file))
    io1, r1, m1 = iocounters(), rss(), majflt()

    println(join((name, file, filesize(joinpath(dir, file)),
                  round(t; digits = 4),
                  io1.rchar - io0.rchar,
                  io1.read_bytes - io0.read_bytes,
                  r1 - r0,
                  m1 - m0,
                  result), '\t'))
    return 0
end

exit(main(ARGS))

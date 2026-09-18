# Does NIfTI.jl lazy-load?

Side experiment, unrelated to the 1BRC code in this repo.

**Question.** Can Julia's NIfTI.jl read individual voxels without pulling the
whole image into memory, so that long load times stop being the bottleneck?

**Answer.** Yes, on an uncompressed `.nii`, via `niread(path; mmap = true)`.
Opening a 1.8 GiB file costs 1.2 ms and 0.06 MiB of resident memory instead of
1.0 s and 1800 MiB. Two caveats decide whether you actually get the win:
gzipped files cannot be mapped at all, and the kernel's readahead window will
silently undo most of the saving unless you ask for `MADV_RANDOM`.

## How it works

`niread` dispatches on the `mmap` keyword (`src/volume.jl` in NIfTI.jl v0.6.3):

```julia
map ? Mmap.mmap(io, A, dim) : read!(io, A(undef, dim))
```

So `mmap = true` is a real `mmap(2)` of the voxel region — pages arrive on
fault — and the default is a full `read!` into a fresh array. For a gzipped
file the mapping branch is unreachable and raises
`cannot mmap a gzipped NIfTI file`, because the decompressed bytes exist
nowhere on disk to be mapped.

## Measurements

`generate.jl` writes the synthetic corpus, `probe.jl` runs one scenario in a
fresh process, `run.jl` drives the set. Each scenario drops the page cache
after warmup, so the numbers describe a cold read. Counters come from
`/proc/self/io`, `/proc/self/statm` and `/proc/self/stat`:

- **read() MiB** — bytes through the read path. Page faults are not counted,
  so this is exactly "how much did the library eagerly load".
- **disk MiB** — bytes actually fetched from the block device, readahead
  included.
- **ΔRSS MiB** — how much of the array ended up resident in the process.

Corpus: `fmri.nii` 128×128×72×400 Float32 (1.8 GiB), the same volume gzipped,
and a 256³ Int16 anatomical in both byte orders. 64 scattered voxels are read
where a scenario says "voxels".

```
scenario           file MiB  wall s   read() MiB  disk MiB  ΔRSS MiB  majflt
-----------------  --------  -------  ----------  --------  --------  ------
eager_open           1800.0   1.0085     1800.06   1802.34   1800.01       1
eager_voxels         1800.0    0.999     1800.06   1800.14   1800.01       0
eager_sumall         1800.0   1.1754     1800.06   1802.34   1800.01       1
mmap_open            1800.0   0.0012        0.09      2.46      0.06       1
mmap_voxels          1800.0   0.1712        0.09    433.44      3.94      57
mmap_timeseries      1800.0   0.6607        0.09   1802.34     25.01     400
mmap_oneslice        1800.0   0.0042        0.09     10.34      0.14       2
mmap_onevolume       1800.0   0.0053        0.09     14.34      9.51       1
mmap_sumall          1800.0   0.6332        0.09   1802.34   1800.01       1
mmap_voxels_rand     1800.0   0.0045        0.09      0.52      0.25      64
mmap_tseries_rand    1800.0   0.0212        0.09      4.02      1.57     401
gz_eager_voxels     1649.83  10.2192     1649.86   1650.11   1800.02       1
gz_mmap_open        1649.83    0.001        0.06       2.6      0.01       2
le_mmap_voxels         32.0   0.0256        0.09     32.27      3.47       6
be_mmap_voxels         32.0   0.0132        0.09     32.27       3.5       6
be_eager_voxels        32.0   0.0194       32.06     32.27      32.0       0
```

Julia 1.13.0, NIfTI.jl v0.6.3, Linux 6.18, ext4.

## What the table says

**The mapping is genuinely lazy.** Every `mmap` scenario reads 0.09 MiB through
`read()` against 1800 MiB for every eager one, and that 0.09 MiB is header
parsing plus the 64 KiB buffer chunk it arrives in — the same fixed cost the
eager rows carry on top of their 1800 MiB. Indexing itself adds nothing:
measured on its own, a single voxel read through the mapping moves 115 bytes
through `read()`, and those 115 bytes are the `/proc/self/io` file opened to
take the measurement. Opening the file and touching one voxel leaves 0.06 MiB
resident. Nothing about the array is loaded until it is indexed.

**Reading a few voxels costs a few voxels' worth of memory.** 64 scattered
voxels leave 3.94 MiB resident, not 1800 MiB. That figure is ≈64 × 63 KiB, which
is the kernel's fault-around behaviour: one fault maps the 16 pages around the
address, so the true granularity is 64 KiB, not the 4 B voxel. Still a 457×
reduction, and 0.25 MiB once readahead is turned off (below).

**Readahead, not NIfTI.jl, is the thing to watch.** `mmap_voxels` pulls 433 MiB
off the disk to deliver 3.94 MiB of pages, and `mmap_timeseries` pulls the
entire 1.8 GiB file. This machine has `read_ahead_kb = 8192`, and 57 major
faults × 8 MiB ≈ 433 MiB accounts for it exactly. One `madvise` call removes it:

```julia
vol = niread(path; mmap = true)
Mmap.madvise!(vol.raw, Mmap.MADV_RANDOM)
```

That is the only difference between the `_rand` rows and their neighbours:

| access pattern | default | `MADV_RANDOM` |
| --- | --- | --- |
| 64 scattered voxels | 0.171 s, 433 MiB disk | 0.005 s, 0.52 MiB disk |
| one voxel's 400-point time series | 0.661 s, 1802 MiB disk | 0.021 s, 4.02 MiB disk |

The time series is the case that matters for fMRI and the case where the naive
mapping helps least: successive timepoints sit 4.5 MiB apart, so 400 of them
touch 400 separate readahead windows and drag in the whole file — 0.66 s
against 1.0 s for just loading it all, a pointless saving. With `MADV_RANDOM`
the same query is 22 ms and 4 MiB. **If you take one thing from this: map the
file *and* set `MADV_RANDOM`, or the lazy load mostly isn't.**

**Contiguity is free.** A single slice `[:, :, z, 1]` (64 KiB contiguous, since
x and y are the leading dimensions) costs 4.2 ms and 0.14 MiB. A whole volume
`[:, :, :, 1]` (4.5 MiB contiguous) costs 5.3 ms. Both against 1.0 s eager.

**Touching everything costs everything, slightly cheaper.** `mmap_sumall` ends
at the full 1800 MiB resident in 0.63 s, versus 1.18 s eager — mapping avoids
the copy into a second buffer, so whole-image work is still modestly better off.

**Gzip rules the whole thing out.** `mmap = true` on a `.nii.gz` raises rather
than silently falling back, which is the right behaviour. Reading 64 voxels out
of the gzipped copy takes 10.2 s — 10× the uncompressed eager read and 2270×
the mapped one — because the entire stream must be inflated to reach any voxel.
Decompress the archive once; do not pay it per query.

**Byte-swapped files stay lazy.** A big-endian file is wrapped in
`mappedarray(ntoh, hton, vol)`, and the wrapper is lazy too: `be_mmap_voxels`
and `le_mmap_voxels` are indistinguishable (3.5 MiB resident, ~0.09 MiB read),
while the eager big-endian read takes the full 32 MiB. The swap happens per
element on access, so foreign-endian data costs nothing extra to map.

## Caveats

- `ΔRSS` for the `_rand` rows is smaller than fault-around would suggest, but
  `MADV_RANDOM` does not disable fault-around directly — fault-around only maps
  pages already resident in the page cache, and with readahead off and a cold
  cache there are none. So each access faults its own single page. That is also
  why major faults rise from 57 to 64: without the 8 MiB window, no voxel lands
  inside a neighbour's readahead any more.
- The corpus is smooth-phantom data with noise, so `fmri.nii.gz` only
  compresses to 92%. Real images compress better, which makes the gzip read
  cheaper but does not change that it is all-or-nothing.
- Cold-cache numbers. Warm, the eager read is still ~1800 MiB of memcpy while
  the mapped read is still ~0.
- The mapping is read-only here (`mode = "r"`). Writing through a mapping
  opened `"r+"` will dirty pages and flush them back to the file.

## Reproducing

```bash
julia --project generate.jl /path/to/scratch   # ~80 s, writes ~3.4 GiB
julia --project run.jl      /path/to/scratch
```

`run.jl` drops the page cache between scenarios, so it needs to run as root;
without that privilege the `disk MiB` and `wall s` columns describe warm reads
and only `read() MiB` and `ΔRSS MiB` stay meaningful.

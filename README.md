# 1BRC in Julia

The [One Billion Row Challenge](https://github.com/gunnarmorling/1brc) in Julia:
aggregate min/mean/max per weather station out of a ~13.8 GB
`<station name>;<temperature>` text file.

```
julia -t auto -O3 --check-bounds=no --startup-file=no bin/brc.jl measurements.txt
```

`-t auto` is load bearing — without it none of the parallel work happens.
`--check-bounds=no` only takes effect as a startup flag, so `@inbounds` is
written explicitly in the hot paths as well.

## Layout

| file | layer |
|:--|:--|
| `src/reference.jl` | the slow, obviously correct oracle every layer is diffed against |
| `src/parse.jl` | SWAR delimiter scanning, name hashing, branchless value parsing |
| `src/table.jl` | open-addressing table keyed by offsets into the mapping |
| `src/scan.jl` | mmap segmentation, atomic work queue, ILP scan cursors |
| `src/output.jl` | half-up rounding and the challenge's output format |
| `src/generate.jl` | measurement file generator |
| `bin/brc.jl` | CLI (`--check` diffs against the oracle, `--time` reports wall time) |
| `bin/generate.jl` | `julia bin/generate.jl 10_000_000 measurements.txt` |
| `scripts/bench.jl` | steady-state timing with compilation excluded |
| `scripts/inspect.jl` | type stability, zero-allocation and codegen checks |
| `test/runtests.jl` | unit tests plus end-to-end diffs against the oracle |
| `test/samples/` | the twelve official 1BRC sample inputs and expected outputs |
| `prepare.sh` | ahead-of-time build, 1BRC's `prepare_<fork>.sh` analogue |
| `calculate_average.sh` | the launch script the benchmark times |
| `test.sh` | correctness gate against the official samples |
| `create_measurements.sh` | generate the input onto a RAM disk |
| `evaluate.sh` | the 1BRC benchmark methodology (see below) |

## What each layer does

**mmap.** The file is mapped as a `Vector{UInt8}`; the hot loop works from a raw
`Ptr{UInt8}` with 0-based offsets throughout (never the 1-based two-argument
`unsafe_load`), inside `GC.@preserve`.

**Dynamic work queue.** The file is cut into 2 MiB segments handed out by a
single atomic counter — the only shared mutable state in the program. A fixed
1/N split would leave every thread waiting on the slowest. Segment starts are
pure arithmetic and each thread repairs its own boundary by skipping to the next
row; a segment's stop is the *same function* applied to the next segment, so
neighbours agree by construction and every row is processed exactly once.

**SWAR scanning and hashing in one pass.** `';'` is located by
`(x - ONES) & ~x & HIGHS` over an 8-byte load, and the name is folded into an
FNV-1a hash in the same loop — the name bytes are read once and no `String` is
ever built.

**Branchless parsing.** One 8-byte load covers `d.d\n` through `-dd.d\n`; a
fixed sequence of ALU ops extracts the value with no branches (the merykitty
trick). Everything stays in tenths of a degree as integers until printing.

**Open addressing.** A fixed 131072-slot table (load factor < 0.08 at the
challenge's 10 000-station cap), struct-of-arrays, with the key stored as an
offset into the mapping rather than a copy. Names are compared in full, so the
result is correct rather than probabilistically correct.

**ILP.** Three independent cursors per segment, advanced round-robin, so the
out-of-order engine has something to do while one stream misses cache.

## Two things measurement changed

*Hash index.* The obvious `(h >> 40) & MASK` costs **1.02 probes per insert**
across 10 000 station names (worst case 112). Adding the finalizer
`h ⊻= h >> 29` and indexing on the low bits costs **0.05** (worst case 3).
`test/runtests.jl` guards this.

*Tail safety.* The fast path reads up to 8 bytes past any offset it touches,
which inside an mmap is only safe because the kernel zero-fills the last partial
page — and is not safe at all when the file size is an exact multiple of the
page size. Rather than depend on that, a 64 KiB tail is carved off the end and
handed to the byte-at-a-time parser: a few thousand rows out of a billion, and
the hot loop keeps no bounds check at all.

## Assumptions

From the challenge spec, and all of them load bearing:

* little-endian machine;
* temperatures are always `-?d?d.d` — one fractional digit, at most two integer
  digits, range `-99.9 .. 99.9`;
* station names are under 100 bytes and contain no `';'` or `'\n'`;
* at most 10 000 distinct stations;
* rows are well formed and newline terminated.

Because aggregation is integer-only, a station whose values are all in
`[-0.05, 0)` prints `0.0` where the Java reference prints `-0.0`.

## Benchmarking the way 1BRC did

The official evaluation is deliberately not a cold-file measurement. From the
1BRC README:

> Programs are run from a RAM disk (i.o. the IO overhead for loading the file
> from disk is not relevant), using 8 cores of the machine.

`evaluate.sh` reproduces that methodology as closely as this machine allows:

```
./prepare.sh                        # ahead-of-time build, so compilation is not timed
./create_measurements.sh 100000000  # input generated onto /dev/shm
./evaluate.sh 10                    # correctness gate, warmup, hyperfine, trimmed mean
```

| 1BRC | here |
|:--|:--|
| input on a RAM disk | `/dev/shm` |
| `numactl --physcpubind=0-7` | `numactl --physcpubind=0-3` (4 cores available) |
| `hyperfine --warmup 0 --runs N` on the launch script | same |
| end-to-end timing, process startup included | same |
| `test.sh` against the samples first, as the warmup | same, against the same samples |
| trimmed mean, fastest and slowest dropped | same jq expression |
| SMT and cpufreq boost warnings | same |
| 1e9 rows / 13.8 GB | 1e8 rows / 1.285 GiB — 13.8 GB does not fit in a 15 GB RAM disk |

`test.sh` runs the twelve official sample files vendored in `test/samples/`,
including `measurements-rounding` and `measurements-10000-unique-keys`,
normalising both sides through 1BRC's own `tocsv.sh`. All twelve pass.

## Numbers

End-to-end on 4 cores, 1e8 rows from `/dev/shm`, trimmed mean of 10 runs:

| | |
|--:|:--|
| **0.621 s** | trimmed mean, end to end |
| 161 M rows/s | end to end, startup included |
| **6.21 s** | extrapolated to 1e9 rows |

Where that time goes:

| | |
|--:|:--|
| 0.174 s | process startup — Julia runtime plus the package image |
| 0.355 s | the scan itself (282 M rows/s, 3.6 GiB/s) |
| ~0.09 s | thread startup and zeroing 4 × 5.2 MB of thread-local tables |

Because 1BRC times the launch script rather than the aggregation, startup is
worth optimising: `src/OneBRC.jl` ends with a precompilation workload that
bakes the hot path's native code into the package image, which took the fixed
cost of a run from **819 ms to 174 ms**. This is the same pressure that pushed
the top JVM entries onto GraalVM native images.

The 5.2 MB-per-thread table is the next thing that harness exposes and an
in-process benchmark hides: `TABLE_BITS` is sized for the 10 000-station cap,
and every fresh process pays to fault in and zero 21 MB of it.

Scan throughput alone, measured in-process with `scripts/bench.jl`
(compilation and startup excluded):

| threads | 1e7 rows | 1e8 rows |
|--:|--:|--:|
| 1 | 0.142 s (70 M rows/s) | |
| 2 | 0.065 s (154 M rows/s) | |
| 4 | 0.034 s (290 M rows/s) | 0.355 s (282 M rows/s) |

Throughput holds as the file grows past cache, so the extrapolation to 1e9 is
close to linear. The three ILP cursors are worth ~7% single-threaded and ~1% at
4 threads, where the loop is already bandwidth bound.

For reference, the official results on 8 cores of a 32-core EPYC 7502P:
1.535 s for the winning entry, and 0.323 s on all 32 cores / 64 threads.

## Tests

```
julia -t auto --startup-file=no test/runtests.jl
julia -t auto -O3 --check-bounds=no --startup-file=no scripts/inspect.jl
```

`parse_value` is checked exhaustively against `parse(Float64, ...)` over every
value from `-99.9` to `99.9` in all four layouts; generated files are diffed
end-to-end against the oracle; and the hot path is asserted to allocate exactly
zero bytes.

## Data

`data/stations.csv` holds the 413 station names and mean temperatures used by
the reference generator, adapted from
[1brc](https://github.com/gunnarmorling/1brc) and ultimately from
[simplemaps.com](https://simplemaps.com/data/world-cities), licensed
CC BY 4.0.

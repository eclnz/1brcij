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

**Open addressing.** A fixed 32768-slot table, each entry packed into exactly
one 64-byte cache line, holding the name's first 16 bytes inline. Names are
compared in full, so the result is correct rather than probabilistically
correct.

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

## Running the real thing

Prerequisites: `julia` (1.10+) on `PATH`, plus `hyperfine`, `jq` and `numactl`.
Set `JULIA=/path/to/julia` if it is not on `PATH`.

```bash
./prepare.sh                          # precompile; do this after every source change
./create_measurements.sh 1000000000   # ~2.5 min, writes 13.8 GB to /dev/shm
BRC_CORES=0-7 ./evaluate.sh 10        # 8 cores, exactly as 1BRC evaluated
```

`/dev/shm` defaults to half of RAM, so the full 1e9 input needs a machine with
about 28 GB, or an enlarged RAM disk:

```bash
sudo mount -o remount,size=16G /dev/shm
```

`create_measurements.sh` refuses to start a run that will not fit rather than
filling the RAM disk and failing near the end. If yours is too small, pass a
smaller row count — `evaluate.sh` will extrapolate and say so.

Two knobs: `BRC_CORES` (default: every core) sets the `numactl --physcpubind`
range, and `BRC_THREADS` (default: as many as there are pinned cores) sets
Julia's thread count. 1BRC also ran with SMT disabled; `evaluate.sh` warns if it
is on, since it adds variance rather than throughput here.

The reported estimate scales only the part that grows with the row count.
Process startup and thread setup are measured separately against a one-row
input and added back, because multiplying them by the scale factor is how a
1e8 run gets mistaken for a much slower 1e9 one.

## Numbers

End-to-end on 4 cores, 1e8 rows from `/dev/shm`, trimmed mean of 15 runs:

| | |
|--:|:--|
| **0.673 s** | trimmed mean, end to end |
| 148.6 M rows/s | end to end, startup included |
| **4.78 s** | estimated for 1e9 rows |

Where that time goes:

| | |
|--:|:--|
| 0.216 s | fixed — process startup, thread setup, table zeroing |
| 0.457 s | scaling — the scan itself |

Only the scaling part is multiplied when estimating 1e9; `evaluate.sh` measures
the fixed part against a one-row input rather than assuming it away.

Because 1BRC times the launch script rather than the aggregation, startup is
worth optimising the way the top JVM entries used GraalVM native images.
`src/OneBRC.jl` ends with a precompilation workload that bakes the hot path's
native code into the package image, which took the fixed cost of a run from
**819 ms to 174 ms**.

### A caveat on every number below

These were taken on a shared VM, and its speed varies between sessions by more
than any single optimisation here is worth: identical code measured 0.567 s in
one session and 0.723 s in another. Every table below is internally consistent
— both arms measured back to back on the same host — but figures from different
tables are not comparable, and none of them will match what you measure. Treat
the percentages as the result and the absolute seconds as incidental.

### Prefetch, but only with somewhere to hide

The table probe is a data-dependent load, and at 10 000 stations it misses L2
regularly. The obvious fix is to prefetch the entry as soon as the hash is
known, so the miss overlaps `parse_value` instead of stalling after it. Measured
on its own, that does nothing: ten cycles of ALU is not enough to cover the
miss, and the extra instruction is not free.

What works is prefetching *and* pipelining the loop — hash all three streams and
issue all three prefetches, then parse and accumulate all three — which gives
each prefetch two further rows of work in front of it. Neither half does
anything alone:

| scan loop, 1e7 rows, one thread | 413 stations | 10 000 stations |
|:--|--:|--:|
| prefetch only, no distance | +1.8% | −0.3% |
| pipelined, no prefetch | ~0% | ~0% |
| **pipelined and prefetching** | **−4%** | **−10%** |

End to end at 1e8 rows that is 0.710 s → 0.659 s and 0.883 s → 0.805 s.

Julia has no prefetch intrinsic, so `prefetch` in `scan.jl` is hand-written LLVM
IR — the most fragile code in the repo, though `llvm.prefetch` lowers to nothing
on targets without the instruction.

### The name never leaves the cache line

The table used to hold its key as an offset into the mapping, so confirming a
probe hit meant reading the name back out of a 13.8 GB region. Those reads are
not cold — there are only as many first-occurrence addresses as there are
stations — but they are a second working set competing with the table itself:
at 10 000 stations that is another 10 000 cache lines.

Storing the name's first 16 bytes in the entry removes it. The comparison then
happens inside the cache line the probe has already loaded, and for a name of
16 bytes or fewer it is exact, so the mapping is never touched a second time.
That covers 95% of the 10 000-name station set and 99% of the reference
generator's 413. Longer names keep the offset and fall through to comparing
the remainder.

| name key held as | 413 stations | 10 000 stations |
|:--|--:|--:|
| offset into the mapping | 0.723 s | 1.006 s |
| **16 bytes inline** | **0.674 s** | **0.888 s** |
| | −6.8% | −11.7% |

As expected, it pays more where there are more distinct names to compete for
cache — which is the case the challenge permits and the reference generator
does not produce.

### Cache lines, not probe counts

The table layout was the largest single win, and the reasoning that produced it
was wrong twice over.

The original design followed the usual advice: struct-of-arrays, sized for a
load factor under 0.08 at the challenge's 10 000-station cap. Both choices
optimise probe count. Probe count turned out not to be what costs — with seven
parallel arrays, one row's update touches up to seven cache lines. Packing an
entry into a single 64-byte line touches one.

Measured end to end, 1e8 rows, 4 cores:

| layout | `TABLE_BITS` | MiB/table | 413 stations | 10 000 stations |
|:--|--:|--:|--:|--:|
| struct-of-arrays | 17 | 5.0 | 0.595 s | 1.286 s |
| struct-of-arrays | 15 | 1.25 | 0.598 s | 0.901 s |
| one cache line per entry | 17 | 8.0 | 0.583 s | 0.860 s |
| **one cache line per entry** | **15** | **2.0** | **0.560 s** | **0.774 s** |

The packed entry is *larger* — 64 bytes against 40 — and uses more memory per
table, and is still 33% faster on the case the spec actually permits. That is
the clearest evidence that the cost here is lines touched, not bytes held and
not probes walked. The two fixes overlap rather than compound: together they
are worth 40%, not the 63% adding them would suggest. Both are in; the last row
is the current configuration.

Sizing the table down narrows the margin over the challenge's 10 000-station
cap from 13x to 3.3x, so `update!` now refuses past half full. The table never
resizes, and without that check a file with more distinct stations than slots
would send the probe loop looking for an empty one forever — a hang rather than
a wrong answer, which is the worse way to fail. The check costs nothing per
row: it runs once per distinct station, on the insert branch only.

At 413 stations, the station set the reference generator produces, every
variant lands within the ±7% run-to-run noise of this machine. The whole effect
lives in the case with enough distinct stations to spill out of cache.

Scan throughput alone, measured in-process with `scripts/bench.jl`
(compilation and startup excluded):

| threads | 1e7 rows | 1e8 rows |
|--:|--:|--:|
| 1 | 0.142 s (70 M rows/s) | |
| 2 | 0.065 s (154 M rows/s) | |
| 4 | 0.034 s (290 M rows/s) | 0.355 s (282 M rows/s) |

(measured with the struct-of-arrays table; the packed layout changes the
10 000-station case, not this one)

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

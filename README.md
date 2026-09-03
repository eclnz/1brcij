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

Every version, built from git and timed back to back on one machine — 1e8 rows
from a RAM disk, 4 threads, scan only, compilation and process startup
excluded. This is the only internally consistent comparison here, and the only
one worth reading as a progression:

| version | 413 stations | 10 000 stations |
|:--|--:|--:|
| original — struct-of-arrays, 131072 slots, key by offset | 0.397 s | 0.986 s |
| + one cache line per entry | 0.363 s | 0.551 s |
| + 32768 slots | 0.369 s | 0.546 s |
| + 16-byte inline key | 0.340 s | 0.471 s |
| + pipelined prefetch | 0.321 s | 0.429 s |
| + five scan cursors | **0.306 s** | **0.407 s** |
| | **1.30× faster** | **2.42× faster** |

Nearly 2.5× on the case the spec permits, and 1.3× on the case the reference
generator actually produces. The gap between those two columns is the whole
story of this repo: every change below targets memory behaviour, and memory
behaviour only bites once there are enough distinct stations to spill out of
cache. Individual rows are noisy — read the endpoints.

### Absolute times mean very little here

These were measured on a shared VM whose speed varies between sessions by more
than any single change below is worth. Identical code, identical input,
measured 0.560 s in one session and 0.723 s in another — a 29% swing with no
code change at all.

So the seconds above are a property of that machine on that afternoon, not of
the implementation. An earlier draft of this file quoted an end-to-end figure of
"4.78 s for 1e9 rows"; that number said more about the host than the code and
has been removed. `./evaluate.sh` will tell you what your machine does.

Read the ratios, not the seconds. And compare only within a single table —
figures from different tables were taken on different days.

### What each change was worth

Measured as its own A/B, each arm run back to back:

| change | 413 stations | 10 000 stations |
|:--|--:|--:|
| one cache line per entry | −10% | −27% |
| 32768 slots | −2% | −11% |
| 16-byte inline key | −10% | −19% |
| pipelined prefetch | −3% | −4% |
| five scan cursors instead of three | −4% | −3% |

Each was measured as its own A/B at four threads. Beware single-threaded
microbenchmarks for the last two: both hide memory latency, and on one core
there is far more latency to hide, so they read −10% and −16% there against the
−3 to −4% they actually deliver.

### Cache lines, not probe counts

The table began as struct-of-arrays sized for a load factor under 0.08 — both
choices optimising probe count. Probe count turned out not to be what costs:
with seven parallel arrays one row's update touches up to seven cache lines,
where a packed 64-byte entry touches one.

The packed entry is *larger* — 64 bytes against 40 — and uses more memory per
table, and is still far faster on the case the spec permits. Shrinking the
table to 32768 slots then overlaps with it rather than compounding: the two
together are worth less than adding their separate results would suggest,
because both were paying down the same cache traffic.

That shrink narrows the margin over the 10 000-station cap from 13× to 3.3×, so
`update!` refuses past half full. The table never resizes, and overfilling it
would leave the probe loop hunting for an empty slot forever — a hang rather
than a wrong answer. The check runs once per distinct station, not per row.

### The name never leaves the cache line

The entry used to hold its key as an offset into the mapping, so confirming a
probe hit meant reading the name back out of a 13.8 GB region. Those reads are
not cold — there are only as many first-occurrence addresses as stations — but
they are a second working set competing with the table itself.

Holding the name's first 16 bytes in the entry removes it. The comparison then
happens inside the cache line the probe has already loaded, and for a name of 16
bytes or fewer it is exact, so the mapping is never touched twice. That covers
95% of the 10 000-name station set and 99% of the reference generator's 413.
Longer names keep the offset and compare the remainder.

### Prefetch, but only with somewhere to hide

The table probe is a data-dependent load that misses L2 regularly at 10 000
stations. Prefetching the entry as soon as the hash is known does nothing on its
own — ten cycles of `parse_value` is not enough to cover the miss, and the
instruction is not free. Pipelining the loop without a prefetch does nothing
either. Together they work, because hashing all three streams before parsing any
of them gives each prefetch two further rows of work to hide behind.

| scan loop, 1e7 rows | 413 stations | 10 000 stations |
|:--|--:|--:|
| prefetch only, no distance | +1.8% | −0.3% |
| pipelined, no prefetch | ~0% | ~0% |
| pipelined and prefetching, one thread | −4% | −10% |
| pipelined and prefetching, four threads | −3% | −4% |

The single-threaded figure is the flattering one: with four cores there is
already memory-level parallelism across them, so less miss latency remains for a
prefetch to hide. Take −4% as the honest number.

Julia has no prefetch intrinsic, so `prefetch` in `scan.jl` is hand-written LLVM
IR — the most fragile code in the repo, though `llvm.prefetch` lowers to nothing
on targets without the instruction.

### Threads

Scan throughput scales close to linearly on this 4-core machine — 1 / 2 / 4
threads measured 4.18× across the range — so it is not memory-bandwidth bound
at four.

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

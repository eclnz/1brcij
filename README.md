# 1BRC in Julia

The [One Billion Row Challenge](https://github.com/gunnarmorling/1brc): min/mean/max
per weather station from a 13.8 GB `<station>;<temperature>` file.

```bash
./benchmark.sh          # prerequisites, build, generate onto a RAM disk, evaluate
```

**3.10 s** for 1e9 rows on four cores, 323 M rows/s, end to end with process
startup counted. The winning Java entry ran 1.535 s on eight cores of a 32-core
EPYC 7502P; its sequential baseline, 4:49.

## Layout

| | |
|:--|:--|
| `src/parse.jl` | delimiter scanning, name hashing, branchless value parsing |
| `src/table.jl` | open-addressing table keyed on the name's first 16 bytes |
| `src/scan.jl` | mmap segmentation, work queue, pipelined scan cursors |
| `src/output.jl` | half-up rounding and the challenge's output format |
| `src/reference.jl` | the slow oracle everything is diffed against |
| `src/safe.jl` | the same algorithm with no unsafe operations, for comparison |
| `src/generate.jl` | measurement file generator |
| `bin/brc.jl` | CLI — `--check` diffs against the oracle, `--time` reports wall time |
| `scripts/bench.jl` | steady-state timing, compilation excluded |
| `scripts/inspect.jl` | type stability, zero-allocation and codegen checks |
| `scripts/safety.jl` | unsafe against safe, checked and unchecked |
| `test/samples/` | the twelve official 1BRC samples and expected outputs |
| `benchmark.sh` | the whole run in one command |
| `prepare.sh` `calculate_average.sh` `test.sh` `create_measurements.sh` `evaluate.sh` | the 1BRC harness scripts |

## How it works

The file is mmapped and read through a raw `Ptr{UInt8}` with 0-based offsets,
inside `GC.@preserve`. It is cut into 2 MiB segments handed out by a single
atomic counter — the only shared mutable state. Segment starts are arithmetic;
each thread repairs its own boundary by skipping to the next row, and a
segment's stop is the same function applied to the next segment, so neighbours
agree by construction.

Per row: one 16-byte `vpcmpeqb` finds the `';'` and its trailing-zero count is
the name length; the name folds into an FNV-1a hash in the same pass; the value
comes out of a single 8-byte load with no branches (the merykitty trick); and
everything stays in integer tenths until printing.

Rows are accumulated into a fixed 32768-slot open-addressing table, one per
thread, merged at the end. Each slot is 32 hot bytes — the name's first 16
bytes, sum, count, min, max — with the name's offset and length in a separate
array touched only on insert, at merge, and for names of 16 bytes or more.
Names are compared in full, so the result is correct rather than probably so.

Five scan cursors run per segment. Row *n+1*'s position is unknown until row
*n* is parsed, so one cursor is a single dependency chain; five give the
out-of-order engine something to overlap. All five hash before any of them
parse, which puts four rows of work between each table prefetch and its use.

## What mattered

Every version rebuilt from git and timed back to back, 1e9 rows, four cores,
end to end, input on 2 MiB pages except where noted:

| | time | |
|:--|--:|--:|
| original, 4 KiB pages | 6.445 s | |
| original | 6.314 s | |
| + precompiled package image | 5.206 s | −17.5% |
| + one cache line per entry | 4.674 s | −10.2% |
| + 32768 slots | 4.797 s | +2.6% |
| + 16-byte inline key | 4.299 s | −10.4% |
| + pipelined prefetch | 4.216 s | −1.9% |
| + five scan cursors | 4.026 s | −4.5% |
| + SIMD delimiter scan | 3.174 s | −21.2% |
| + 32-byte hot entry | 3.086 s | −2.8% |
| HEAD, 4 KiB pages | 3.408 s | +10.1% |

Against the reference oracle in the same process: **22× on one core, 86× on
four**.

Three things are worth extracting from that table.

**Cache lines, not operation counts.** The table began as struct-of-arrays sized
for a load factor under 0.08 — both choices optimising probe count, which turned
out not to be what costs. A packed 64-byte entry touches one cache line where
seven parallel arrays touch seven. The packed entry is *larger* and still much
faster.

**Distance, not instructions.** Prefetching the table entry buys nothing on its
own, and pipelining the loop buys nothing on its own; together they are worth
10%, because only then does each prefetch have enough work in front of it.

**The row above going the wrong way is not an error.** 32768 slots measured
neutral on the 413-station set and worth 11% at 10 000. This is the 413-station
input the reference generator produces, so most of this table understates
itself — several rows are worth two to four times more at the station count the
spec permits. The SIMD scan is the exception, and the only change that reduces
work per row rather than misses per row.

Things that measured *worse* and were dropped: branchless min/max, a 24-byte
inline key, fusing count/min/max into one word, and `MADV_POPULATE_READ`. Three
of the four reduced operation counts at the cost of parallelism.

### What the unsafe machinery buys

`src/safe.jl` is the same algorithm with no `unsafe_load`, no raw pointers, no
`llvmcall` and no `@inbounds`. 1e8 rows, four cores, best of seven:

| | 413 stations | 10 000 stations |
|:--|--:|--:|
| unsafe, checks off (shipped) | 0.274 s | 0.387 s |
| safe, checks off | 0.404 s | 0.534 s |
| safe, bounds checked | 0.546 s | 0.705 s |

**Pure safe Julia costs about 2×**, split roughly evenly between the two
intrinsics that have no safe equivalent — the 16-byte `vpcmpeqb` scan and the
table prefetch — and bounds checking.

What it does *not* cost is the pointer arithmetic. `unsafe_load` buys nothing
here: assembling a `UInt64` from eight `Vector{UInt8}` indexes compiles to a
single `mov rax, qword ptr [rax + rsi - 1]`, identical to the pointer version,
because LLVM widens the byte loads. So the unsafe code is worth having for the
intrinsics it unlocks and for eliding bounds checks, not for the addressing.

`scripts/safety.jl` reproduces the table; `test/runtests.jl` holds the two
implementations to identical output.

### Thread scaling

| cores | time | M rows/s | speedup |
|--:|--:|--:|--:|
| 1 | 9.181 s | 108.9 | 1.00× |
| 2 | 4.684 s | 213.5 | 1.96× |
| 3 | 3.201 s | 312.4 | 2.87× |
| 4 | 2.486 s | 402.2 | 3.69× |

Amdahl fits to within 0.8% at `T(n) = 0.229 + 8.945/n`, and its serial term
lands on the 0.20 s of startup measured independently. Extrapolating: 1.35 s at
eight cores, or 1.49 s under the Universal Scalability Law, which allows for
degradation and peaks near sixteen. Treat that as an indication — it doubles
beyond the measured range on a 4-core VM.

### Huge pages

At 1e9 rows the input is 3.4 million 4 KiB pages that every run faults in.
Backing it with 2 MiB pages is worth **10%** — user time is unchanged, and the
whole difference is kernel time plus TLB coverage.

This is a mount option, not a patch. `madvise` cannot do it: the kernel will not
promote tmpfs pages already allocated at 4 KiB, so the setting has to precede
the write, and `transparent_hugepage/shmem_enabled` alone is not enough either.

```bash
sudo mount -o remount,huge=always /dev/shm    # then regenerate the input
```

`create_measurements.sh` checks and says so.

### On the numbers

Absolute times move about 20% between sessions on the shared VM these were taken
on — identical code and input measured 2.51 s and 3.10 s on different days — so
each table is internally consistent and comparable to nothing else here. Read
the ratios.

## Benchmarking

`evaluate.sh` follows 1BRC's own methodology: input from a RAM disk so I/O is
not measured, the correctness suite as a gate, one full run as warmup, then
`hyperfine --warmup 0` timing the launch script end to end under
`numactl --physcpubind`, reported as a trimmed mean. It pins to cores 0-7 where
there are eight, matching the official evaluation, and prints any deviation.

Prerequisites: `julia` 1.10+, `hyperfine`, `jq`, `numactl`, `bc`. Set `JULIA=`
if julia is not on `PATH`. The full input needs ~14 GB of RAM disk; pass a
smaller row count and the harness extrapolates and says so.

## Assumptions

From the challenge spec, all load-bearing: little-endian; temperatures of the
form `-?d?d.d` in `-99.9 .. 99.9`; station names under 100 bytes containing no
`';'` or newline; at most 10 000 distinct stations; well-formed, newline-
terminated rows.

Because aggregation is integer-only, a station whose values all fall in
`[-0.05, 0)` prints `0.0` where the Java reference prints `-0.0`.

## Tests

```bash
julia -t auto --startup-file=no test/runtests.jl
julia -t auto -O3 --check-bounds=no --startup-file=no scripts/inspect.jl
./test.sh
```

`parse_value` is checked exhaustively against `parse(Float64, ...)` over every
value from `-99.9` to `99.9`; generated files are diffed end to end against the
oracle; the hot path is asserted to allocate zero bytes; and `./test.sh` runs
the twelve official 1BRC samples through their own `tocsv.sh`.

## Data

`data/stations.csv` holds the 413 station names and mean temperatures used by
the reference generator, adapted from [1brc](https://github.com/gunnarmorling/1brc)
and ultimately from [simplemaps.com](https://simplemaps.com/data/world-cities),
CC BY 4.0. The samples under `test/samples/` come from the same repository,
Apache 2.0.

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

## Numbers

4 cores (Ubuntu 24.04, Julia 1.12), 10 M rows / 0.128 GiB, warm page cache,
steady state:

| threads | best | throughput |
|--:|--:|--:|
| 1 | 0.142 s | 70 M rows/s |
| 2 | 0.065 s | 154 M rows/s |
| 4 | 0.034 s | 290 M rows/s (3.7 GiB/s) |

The three ILP cursors are worth ~7% single-threaded and ~1% at 4 threads, where
the loop is already bandwidth bound — the guide's "last several percent".

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

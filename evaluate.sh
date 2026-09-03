#!/bin/bash
#
# Benchmark harness, following 1BRC's evaluate.sh as closely as this machine
# allows:
#
#   * the input is read from a RAM disk, so I/O is not part of the measurement
#     (1BRC: "Programs are run from a RAM disk (i.o. the IO overhead for
#     loading the file from disk is not relevant)");
#   * the correctness suite must pass before anything is timed;
#   * one full run over the measurements file first, as the warmup;
#   * `hyperfine --warmup 0 --runs N` times the *launch script* end to end, so
#     process startup counts;
#   * execution is pinned with numactl --physcpubind;
#   * the reported figure is the trimmed mean: drop the fastest and the slowest
#     run, average the rest (the same jq expression 1BRC uses).
#
# Deviations from the official setup are printed at the end of the run.
#
# usage: ./evaluate.sh [runs]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RUNS="${1:-${BRC_RUNS:-10}}"
CORES="${BRC_CORES:-0-$(( $(nproc) - 1 ))}"
NCORES=$(awk -F- '{print $2 - $1 + 1}' <<< "$CORES")
export BRC_THREADS="${BRC_THREADS:-$NCORES}"

for cmd in hyperfine jq numactl; do
  command -v "$cmd" >/dev/null || { echo "$cmd is not installed" >&2; exit 1; }
done

# 1BRC's evaluate.sh warns about both of these, because they add variance.
if [ -f /sys/devices/system/cpu/smt/active ] && [ "$(cat /sys/devices/system/cpu/smt/active)" != "0" ]; then
  echo "WARNING: SMT is enabled"
fi
if [ -f /sys/devices/system/cpu/cpufreq/boost ] && [ "$(cat /sys/devices/system/cpu/cpufreq/boost)" != "0" ]; then
  echo "WARNING: CPU boost is enabled"
fi

if [ ! -e measurements.txt ]; then
  echo "no measurements.txt; run ./create_measurements.sh first" >&2
  exit 1
fi
INPUT=$(readlink -f measurements.txt)
case "$(df --output=fstype "$INPUT" | tail -1)" in
  tmpfs|ramfs) ;;
  *) echo "WARNING: $INPUT is not on a RAM disk; the timing includes disk I/O" ;;
esac

[ -x ./prepare.sh ] && ./prepare.sh

echo
echo "== correctness"
./test.sh > /dev/null || { echo "test suite failed; not benchmarking" >&2; exit 1; }
echo "official 1BRC samples: all passed"

echo
echo "== warmup"
./calculate_average.sh > /dev/null

echo
echo "== timing"
timing=$(mktemp /tmp/brc-timing-XXXXXX.json)
numactl --physcpubind="$CORES" \
  hyperfine --warmup 0 --runs "$RUNS" --style basic \
            --export-json "$timing" --output ./last-run.out \
            './calculate_average.sh'

trimmed=$(jq -r '.results[0].times | sort_by(.|tonumber) | .[1:-1] | add / length' "$timing")
rows=$(wc -l < "$INPUT")
bytes=$(stat -c%s "$INPUT")

echo
echo "== result"
printf 'trimmed mean   %.3f s   (drop fastest and slowest of %d runs)\n' "$trimmed" "$RUNS"
printf 'input          %s rows, %.3f GiB, on %s\n' "$rows" \
       "$(bc -l <<< "$bytes / 1073741824")" "$(df --output=target "$INPUT" | tail -1)"
printf 'throughput     %.1f M rows/s\n' "$(bc -l <<< "$rows / $trimmed / 1000000")"
printf 'cores          %s (%s threads)\n' "$CORES" "$BRC_THREADS"
printf 'extrapolated   %.2f s for 1e9 rows\n' "$(bc -l <<< "1000000000 * $trimmed / $rows")"
echo
echo "deviations from the official 1BRC setup:"
echo "  cores:  $NCORES here, 8 in the official evaluation (32-core EPYC 7502P)"
echo "  rows:   $rows here; the challenge uses 1e9 (13.8 GB), which needs a RAM disk this machine does not have"
rm -f "$timing"

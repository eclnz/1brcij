#!/bin/bash
#
# Benchmark harness, following 1BRC's evaluate.sh as closely as this machine
# allows: input from a RAM disk so I/O is not measured, the correctness suite
# as a gate, one full run as the warmup, then hyperfine timing the launch
# script end to end under numactl pinning, reported as a trimmed mean.
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

# 1BRC warns about both: they add variance, not throughput.
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

# Startup and thread setup do not grow with the row count, so scaling the whole
# end-to-end time would inflate the estimate by that fixed cost times the scale
# factor. Measure it on a trivial input and scale only the rest.
fixed_json=$(mktemp /tmp/brc-fixed-XXXXXX.json)
numactl --physcpubind="$CORES" \
  hyperfine --warmup 2 --runs 5 --style none --export-json "$fixed_json" \
            './calculate_average.sh test/samples/measurements-1.txt' > /dev/null
fixed=$(jq -r '.results[0].times | sort_by(.|tonumber) | .[1:-1] | add / length' "$fixed_json")
rm -f "$fixed_json"
variable=$(bc -l <<< "$trimmed - $fixed")

echo
echo "== result"
printf 'trimmed mean   %.3f s   (drop fastest and slowest of %d runs)\n' "$trimmed" "$RUNS"
printf 'input          %s rows, %.3f GiB, on %s\n' "$rows" \
       "$(bc -l <<< "$bytes / 1073741824")" "$(df --output=target "$INPUT" | tail -1)"
printf 'throughput     %.1f M rows/s   (end to end, startup included)\n' \
       "$(bc -l <<< "$rows / $trimmed / 1000000")"
printf 'cores          %s (%s threads)\n' "$CORES" "$BRC_THREADS"
printf '  fixed        %.3f s   startup and thread setup, independent of row count\n' "$fixed"
printf '  scaling      %.3f s   the scan itself\n' "$variable"
if [ "$rows" -eq 1000000000 ]; then
  printf 'this IS the 1e9 challenge input; no extrapolation needed\n'
else
  printf 'estimated      %.2f s for 1e9 rows   (%.3f fixed + %.3f x %.1f)\n' \
    "$(bc -l <<< "$fixed + $variable * 1000000000 / $rows")" "$fixed" "$variable" \
    "$(bc -l <<< "1000000000 / $rows")"
  printf '               extrapolated from %s rows; linearity is verified 1e7 -> 1e8 only\n' "$rows"
fi
echo
echo "deviations from the official 1BRC setup:"
if [ "$NCORES" -ne 8 ]; then
  echo "  cores:  $NCORES here, 8 in the official evaluation (32-core EPYC 7502P)"
  echo "          set BRC_CORES=0-7 to match it exactly"
fi
if [ "$rows" -ne 1000000000 ]; then
  echo "  rows:   $rows here; the challenge uses 1e9 (13.8 GB)"
fi
rm -f "$timing"

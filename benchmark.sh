#!/bin/bash
#
# Everything in one command: check prerequisites, build, put the input on a RAM
# disk, run the 1BRC evaluation.
#
#   ./benchmark.sh              # the full 1e9-row challenge
#   ./benchmark.sh 100000000    # a tenth of it, if the RAM disk is small
#   ./benchmark.sh 1000000000 5 # ... and only 5 timed runs
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ROWS="${1:-1000000000}"
RUNS="${2:-10}"
RAMDISK="${BRC_RAMDISK:-/dev/shm}"

fail=0
say() { printf '%s\n' "$*"; }

say "== prerequisites"
for cmd in julia hyperfine jq numactl bc; do
  if command -v "$cmd" >/dev/null || { [ "$cmd" = julia ] && [ -x "${JULIA:-}" ]; }; then
    say "  ok       $cmd"
  else
    say "  MISSING  $cmd"
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  say ""
  say "install what is missing, then re-run:"
  say "  Debian/Ubuntu   sudo apt-get install -y hyperfine jq numactl bc"
  say "  macOS           brew install hyperfine jq bc     # numactl is Linux-only"
  say "  julia           https://julialang.org/downloads/  (or: curl -fsSL https://install.julialang.org | sh)"
  say "  or point at an existing install with  JULIA=/path/to/julia ./benchmark.sh"
  exit 1
fi

say ""
say "== RAM disk"
need_mb=$(( ROWS / 1000000 * 14 ))          # ~14 bytes per row
free_mb=$(( $(df -k --output=avail "$RAMDISK" 2>/dev/null | tail -1) / 1024 ))
say "  $RAMDISK has ${free_mb} MiB free, ${ROWS} rows need about ${need_mb} MiB"
if [ "$need_mb" -gt "$free_mb" ]; then
  say ""
  say "  not enough room. either enlarge the RAM disk:"
  say "      sudo mount -o remount,size=$(( (need_mb + 2048) / 1024 ))G $RAMDISK"
  say "  or run a smaller input, which the harness will extrapolate from:"
  say "      ./benchmark.sh $(( free_mb / 14 * 1000000 ))"
  exit 1
fi

if ! grep -q " $RAMDISK .*huge=" /proc/mounts 2>/dev/null; then
  say ""
  say "  note: no huge= mount option on $RAMDISK. Backing the input with 2 MiB"
  say "        pages is worth about 10% at 1e9 rows, and must be set before the"
  say "        file is written:"
  say "            sudo mount -o remount,huge=always $RAMDISK"
fi

if [ -f /sys/devices/system/cpu/smt/active ] && [ "$(cat /sys/devices/system/cpu/smt/active)" != "0" ]; then
  say ""
  say "  note: SMT is on. 1BRC evaluated with it off; it adds variance here."
fi

# 1BRC pinned to eight cores. Match that where there are enough, else use all.
if [ -z "${BRC_CORES:-}" ] && [ "$(nproc)" -ge 8 ]; then
  export BRC_CORES=0-7
  say ""
  say "== cores"
  say "  pinning to 0-7 to match the official evaluation (override with BRC_CORES)"
fi

say ""
say "== build"
./prepare.sh || exit 1

say ""
say "== input"
./create_measurements.sh "$ROWS" || exit 1

say ""
./evaluate.sh "$RUNS"

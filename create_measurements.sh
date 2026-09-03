#!/bin/bash
#
# Create the input file on a RAM disk and point ./measurements.txt at it,
# mirroring 1BRC's create_measurements.sh plus the RAM disk the official
# evaluation ran from.
#
# usage: ./create_measurements.sh [row count]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA="${JULIA:-julia}"
ROWS="${1:-${BRC_ROWS:-100000000}}"
RAMDISK="${BRC_RAMDISK:-/dev/shm}"
TARGET="$RAMDISK/measurements-$ROWS.txt"

if [ ! -d "$RAMDISK" ]; then
  echo "no RAM disk at $RAMDISK; set BRC_RAMDISK" >&2
  exit 1
fi

# ~13.8 bytes per row.  Refuse to start a run that cannot fit, rather than
# filling the RAM disk and failing most of the way through.
need=$(( ROWS * 14 / 1024 ))
free=$(df -k --output=avail "$RAMDISK" | tail -1)
if [ "$need" -gt "$free" ]; then
  echo "$ROWS rows need ~$((need / 1024)) MiB but $RAMDISK has $((free / 1024)) MiB free" >&2
  exit 1
fi

if [ ! -f "$TARGET" ]; then
  "$JULIA" -O3 --startup-file=no "$HERE/bin/generate.jl" "$ROWS" "$TARGET"
else
  echo "reusing $TARGET"
fi

ln -sf "$TARGET" "$HERE/measurements.txt"
ls -l "$HERE/measurements.txt"

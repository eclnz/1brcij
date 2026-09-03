#!/bin/bash
#
# Create the input on a RAM disk and point ./measurements.txt at it, as the
# official evaluation did.
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

# ~14 bytes per row. Refuse up front rather than filling the disk and failing
# most of the way through — but only when there is something to write.
if [ ! -f "$TARGET" ]; then
  need=$(( ROWS * 14 / 1024 ))
  free=$(df -k --output=avail "$RAMDISK" | tail -1)
  if [ "$need" -gt "$free" ]; then
    echo "$ROWS rows need ~$((need / 1024)) MiB but $RAMDISK has $((free / 1024)) MiB free" >&2
    exit 1
  fi
fi

# Huge pages must be in place BEFORE the file is written: the kernel cannot
# promote tmpfs pages already allocated at 4 KiB, and neither the sysfs knob nor
# madvise on the mapping will do it afterwards. Worth about 10% at 1e9 rows.
if ! grep -q " $RAMDISK .*huge=" /proc/mounts 2>/dev/null; then
  echo "note: $RAMDISK has no huge= mount option, so the input will be backed by"
  echo "      4 KiB pages. Measured at 1e9 rows that costs about 10%. To enable,"
  echo "      remount and then regenerate — the order matters:"
  echo "          sudo mount -o remount,huge=always $RAMDISK"
  echo ""
fi

if [ ! -f "$TARGET" ]; then
  "$JULIA" -O3 --startup-file=no "$HERE/bin/generate.jl" "$ROWS" "$TARGET"
else
  echo "reusing $TARGET"
fi

ln -sf "$TARGET" "$HERE/measurements.txt"
ls -l "$HERE/measurements.txt"

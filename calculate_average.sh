#!/bin/bash
#
# The script the benchmark times, mirroring 1BRC's calculate_average_<fork>.sh:
# reads ./measurements.txt and writes the result to stdout.
#
# 1BRC times this end to end, startup included, so --project= matters: it picks
# up the package image ./prepare.sh builds instead of JIT-compiling every run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA="${JULIA:-julia}"
THREADS="${BRC_THREADS:-$(nproc)}"
INPUT="${1:-measurements.txt}"

exec "$JULIA" --project="$HERE" -t "$THREADS" -O3 --check-bounds=no \
     --startup-file=no -e 'using OneBRC; exit(OneBRC.main(ARGS))' -- "$INPUT"

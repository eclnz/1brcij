#!/bin/bash
#
# The launch script the benchmark times, mirroring 1BRC's
# calculate_average_<fork>.sh: it reads ./measurements.txt (a symlink the
# harness points at the input) and writes the result to stdout.
#
# Everything the timing depends on lives here, because 1BRC measures the script
# end to end — process startup included.  That is what made GraalVM native
# images worth 3+ seconds to the JVM entries; the Julia equivalent is loading a
# precompiled package image rather than JIT-compiling on every run, which is
# what ./prepare.sh builds and what --project= below picks up.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA="${JULIA:-julia}"
THREADS="${BRC_THREADS:-$(nproc)}"
INPUT="${1:-measurements.txt}"

exec "$JULIA" --project="$HERE" -t "$THREADS" -O3 --check-bounds=no \
     --startup-file=no -e 'using OneBRC; exit(OneBRC.main(ARGS))' -- "$INPUT"

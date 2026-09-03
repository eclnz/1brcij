#!/bin/bash
#
# 1BRC's prepare_<fork>.sh: the ahead-of-time build, run once before timing.
# Where the JVM entries built a GraalVM native image, Julia precompiles to a
# package image, bringing `using OneBRC` down to bare-Julia startup.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA="${JULIA:-julia}"

"$JULIA" --project="$HERE" --startup-file=no -e 'using Pkg; Pkg.precompile()'

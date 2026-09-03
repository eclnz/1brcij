#!/bin/bash
#
# 1BRC's prepare_<fork>.sh analogue: the ahead-of-time build step, run once
# before timing so that compilation is not measured.
#
# The JVM entries built a GraalVM native image here.  Julia's equivalent is
# precompiling the package to a native code image (.ji + .so), which brings
# `using OneBRC` down to the cost of starting bare Julia.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA="${JULIA:-julia}"

"$JULIA" --project="$HERE" --startup-file=no -e 'using Pkg; Pkg.precompile()'

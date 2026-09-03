#!/bin/bash
#
# Correctness gate, mirroring 1BRC's test.sh. Both sides go through tocsv.sh so
# a difference is reported per station rather than as one enormous line.
#
# usage: ./test.sh ['test/samples/*.txt']
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

INPUT=${1:-"test/samples/*.txt"}
failed=0
passed=0

for sample in $(ls $INPUT); do
  expected="${sample%.txt}.out"
  if [ ! -f "$expected" ]; then
    echo "SKIP  $sample (no expected output)"
    continue
  fi

  if diff --color=always \
       <(./calculate_average.sh "$sample" | ./tocsv.sh) \
       <(./tocsv.sh < "$expected"); then
    echo "PASS  $sample"
    passed=$((passed + 1))
  else
    echo "FAIL  $sample"
    failed=$((failed + 1))
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

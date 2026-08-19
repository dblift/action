#!/bin/bash
set -euo pipefail

# Test suite entry point: discover and run all tests/test-*.sh in sorted order
failures=0

while IFS= read -r -d '' test_file; do
  test_name=$(basename "$test_file")

  if bash "$test_file"; then
    echo "PASS: $test_name"
  else
    echo "FAIL: $test_name"
    ((failures++))
  fi
done < <(find "$(dirname "$0")" -name 'test-*.sh' -type f -print0 | sort -z)

exit "$failures"

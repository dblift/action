#!/bin/bash
# Verify scripts/check-docs.sh guards Global Constraint 6 (public-repository
# hygiene): it must pass on this repository as committed, and it must reject
# a tracked Markdown file that names a forbidden token.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
check_script="$repo_root/scripts/check-docs.sh"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# --- Case 1: the guard passes on the repository as written ------------------

if ! bash "$check_script" > /dev/null 2>&1; then
  fail "case1: check-docs.sh exited non-zero on the repository as written"
fi

# --- Case 2: a tracked Markdown file naming a forbidden token fails the
# guard. check-docs.sh scans tracked files (git ls-files), so the scratch
# file must actually be staged for it to be seen -- an untracked file would
# make this check pass regardless of whether the guard works. The trap
# below unstages and removes the scratch file even if the test aborts
# partway.

scratch_rel="tests/fixtures/check-docs-scratch.md"
scratch_file="$repo_root/$scratch_rel"

cleanup() {
  git -C "$repo_root" rm -f --cached --quiet -- "$scratch_rel" > /dev/null 2>&1 || true
  rm -f "$scratch_file"
}
trap cleanup EXIT

printf '%s\n' "Scratch file for tests/test-check-docs.sh. Mentions DBLIFT_LICENSE_KEY." > "$scratch_file"
git -C "$repo_root" add -- "$scratch_rel"

if bash "$check_script" > /dev/null 2>&1; then
  fail "case2: check-docs.sh exited 0 despite a tracked file containing a forbidden token"
fi

cleanup
trap - EXIT

if [ "$failures" -eq 0 ]; then
  echo "test-check-docs.sh: all cases passed"
fi

exit "$failures"

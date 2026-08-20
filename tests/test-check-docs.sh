#!/bin/bash
# Verify scripts/check-docs.sh does what it claims: pass on this repository
# as committed, reject a tracked file that names a token from its denylist,
# and fail loudly rather than silently outside a git work tree.
#
# The guard is a denylist over literal tokens, not a complete check of the
# public-repository constraint -- it says nothing about which commands the
# documentation names or how many external links it carries -- so these cases
# only cover the token scan.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
check_script="$repo_root/scripts/check-docs.sh"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# The token planted by the cases below is read out of check-docs.sh's own
# $forbidden_tokens list rather than hardcoded here. check-docs.sh scans
# tracked *.sh files, so a literal copy in this file would itself trip the
# guard; deriving it also keeps the test honest about whatever the guard
# actually forbids today, instead of pinning a second copy that can drift.
planted_token=$(
  sed -n '/^forbidden_tokens=(/,/^)/p' "$check_script" |
    sed -n "s/^  '\\(.*\\)'\$/\\1/p" |
    head -n1
)

if [ -z "$planted_token" ]; then
  echo "ERROR: could not read a forbidden token out of $check_script" >&2
  exit 1
fi

# --- Case 1: the guard passes on the repository as written ------------------

if ! bash "$check_script" > /dev/null 2>&1; then
  fail "case1: check-docs.sh exited non-zero on the repository as written"
fi

# --- Case 2: a tracked file naming a forbidden token fails the guard, in
# every file type the guard claims to scan. check-docs.sh scans tracked files
# (git ls-files), so each scratch file must actually be staged for it to be
# seen -- an untracked file would make this check pass regardless of whether
# the guard works. The trap below unstages and removes the scratch file even
# if the test aborts partway.
#
# Every extension here is covered on purpose: the guard scans shell and YAML
# as well as Markdown, because the workaround that motivated the widening
# lived in a tracked .sh file, not in documentation. Testing only .md would
# let the scan be narrowed back to Markdown with the suite still green.

scratch_rel=""
scratch_file=""

cleanup() {
  if [ -n "$scratch_rel" ]; then
    git -C "$repo_root" rm -f --cached --quiet -- "$scratch_rel" > /dev/null 2>&1 || true
  fi
  if [ -n "$scratch_file" ]; then
    rm -f "$scratch_file"
  fi
}
trap cleanup EXIT

# Named check-docs-scratch.* rather than test-*.sh so that the .sh variant is
# not picked up as a test file by tests/run.sh's discovery glob.
for extension in md sh yml; do
  scratch_rel="tests/fixtures/check-docs-scratch.${extension}"
  scratch_file="$repo_root/$scratch_rel"

  printf '%s\n' "# Scratch file for tests/test-check-docs.sh. Mentions ${planted_token}." > "$scratch_file"
  git -C "$repo_root" add -- "$scratch_rel"

  if bash "$check_script" > /dev/null 2>&1; then
    fail "case2/${extension}: check-docs.sh exited 0 despite a tracked .${extension} file containing a forbidden token"
  fi

  cleanup
done

scratch_rel=""
scratch_file=""
trap - EXIT

# --- Case 3: outside a git work tree, the guard must fail loudly rather
# than silently reporting a clean scan. `git ls-files` failing inside a
# `while ... done < <(process substitution)` is invisible to
# `set -euo pipefail`; a non-git directory with a forbidden token in it
# must not read as "no forbidden tokens found". check-docs.sh has no
# dependency on the rest of the repository, so copying just the script is
# enough to reproduce it outside any git work tree -- the trap removes the
# temp directory even if the test aborts partway.

nogit_dir=$(mktemp -d "${TMPDIR:-/tmp}/check-docs-nogit.XXXXXX")

cleanup_nogit() {
  rm -rf "$nogit_dir"
}
trap cleanup_nogit EXIT

mkdir -p "$nogit_dir/scripts"
cp "$check_script" "$nogit_dir/scripts/check-docs.sh"
printf '%s\n' "Leaks ${planted_token} outside any git work tree." > "$nogit_dir/leak.md"

if bash "$nogit_dir/scripts/check-docs.sh" > /dev/null 2>&1; then
  fail "case3: check-docs.sh exited 0 outside a git work tree instead of failing loudly"
fi

cleanup_nogit
trap - EXIT

if [ "$failures" -eq 0 ]; then
  echo "test-check-docs.sh: all cases passed"
fi

exit "$failures"

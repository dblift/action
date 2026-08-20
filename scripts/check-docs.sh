#!/bin/bash
# Token guard for public-repository hygiene: fail the build if any tracked
# file names a licensing or configuration identifier that belongs to
# installations this Action does not document.
#
# SCOPE -- this script checks exactly one thing: that none of the literal
# strings in $forbidden_tokens appears in a scanned file. It is a denylist,
# not a complete check of the public-repository constraint. It does NOT
# verify that the documented command surface is limited to the open-source
# commands, and it does NOT check how many external links the documentation
# carries. Those remain review responsibilities.
#
# Scans tracked files only, via `git ls-files` -- not a filesystem walk --
# so it never trips on scratch output under tests/tmp/ or other
# untracked/build artifacts.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

# `git ls-files` below runs inside a `while ... done < <(...)` process
# substitution, whose exit status is invisible to the enclosing loop even
# under `set -o pipefail` -- a failure there would otherwise be swallowed,
# leaving `failures` at 0 and reporting a clean scan that never actually
# ran. Failing loudly here up front closes that hole.
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "check-docs.sh: '$repo_root' is not inside a git work tree -- cannot scan tracked files" >&2
  exit 1
fi

# Tokens that must never appear anywhere in this repository's tracked files.
# Keep the list in one place. Each literal is assembled from two adjacent
# string halves so that this script's own source never contains a forbidden
# token as a contiguous string: the scan below can then cover every tracked
# file, this one included, with no exclusion list.
forbidden_tokens=(
  '--license''-key'
  'DBLIFT_''LICENSE_KEY'
  'license''_info'
  'DBLIFT_DISABLE_''CLI_EXTENSIONS'
)

failures=0

while IFS= read -r path; do
  for token in "${forbidden_tokens[@]}"; do
    if grep -qiF -- "$token" "$path"; then
      echo "check-docs.sh: $path contains forbidden token '$token'" >&2
      failures=$((failures + 1))
    fi
  done
done < <(git ls-files)

if [ "$failures" -eq 0 ]; then
  echo "check-docs.sh: no forbidden tokens found"
fi

exit "$failures"

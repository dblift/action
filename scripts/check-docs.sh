#!/bin/bash
# Token guard for public-repository hygiene: fail the build if any tracked
# Markdown, shell or YAML file names a licensing or configuration identifier
# that belongs to installations this Action does not document.
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

# Tokens that must never appear anywhere in this repository's tracked
# documentation, scripts or workflow definitions. Keep the list in one place.
forbidden_tokens=(
  '--license-key'
  'DBLIFT_LICENSE_KEY'
  'license_info'
  'DBLIFT_DISABLE_CLI_EXTENSIONS'
)

# Paths excluded from the scan, each necessarily containing a forbidden
# token for the reason given, not by oversight:
#   - scripts/check-docs.sh: this script, which must name every token in
#     $forbidden_tokens in order to forbid it.
excluded_paths=(
  'scripts/check-docs.sh'
)

is_excluded() {
  local path="$1" excluded
  for excluded in "${excluded_paths[@]}"; do
    if [ "$path" = "$excluded" ]; then
      return 0
    fi
  done
  return 1
}

failures=0

while IFS= read -r path; do
  case "$path" in
    *.md) ;;
    *.sh) ;;
    *.yml) ;;
    *.yaml) ;;
    *) continue ;;
  esac

  if is_excluded "$path"; then
    continue
  fi

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

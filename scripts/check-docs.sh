#!/bin/bash
# Guard Global Constraint 6 (public-repository hygiene): this repository
# documents the open-source command surface only. Fail the build if any
# tracked Markdown file or action.yml names a licensing or configuration
# identifier that belongs to installations this Action does not document.
#
# Scans tracked files only, via `git ls-files` -- not a filesystem walk --
# so it never trips on scratch output under tests/tmp/ or other
# untracked/build artifacts.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

# Tokens that must never appear in this repository's public-facing docs or
# in action.yml. Keep the list in one place.
forbidden_tokens=(
  '--license-key'
  'DBLIFT_LICENSE_KEY'
  'license_info'
)

# Paths excluded from the scan, each necessarily containing a forbidden
# token for the reason given, not by oversight:
#   - scripts/check-docs.sh: this script, which must name every token in
#     $forbidden_tokens in order to forbid it.
#   - docs/plans/action-mvp.md: the internal implementation plan, which
#     states Global Constraint 6 in prose and therefore names the same
#     tokens for the same reason. It is not published documentation of the
#     Action's command surface.
excluded_paths=(
  'scripts/check-docs.sh'
  'docs/plans/action-mvp.md'
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
    action.yml) ;;
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

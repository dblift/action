#!/bin/bash
# Post the rendered migration plan as a single, sticky pull request comment,
# updated on every push rather than posted anew each time.
#
# Usage: comment.sh <markdown-file>
#
# Reads GITHUB_REPOSITORY, GITHUB_EVENT_PATH, GITHUB_STEP_SUMMARY and
# RUNNER_TEMP from the environment (as set by the runner), and needs an
# authentication token exported for `gh`. action.yml supplies that as GH_TOKEN;
# this script never reads the token itself, it only relies on `gh` picking it
# up from the environment.
#
# When $GITHUB_EVENT_PATH does not resolve to a pull request number, or `gh`
# is missing, or any `gh` call fails (e.g. a read-only token on a fork pull
# request), the body is written to $GITHUB_STEP_SUMMARY instead and the
# script exits 0 — posting a comment is a convenience and must never fail
# the job.
#
# Test-only hook, not used in production:
#   GH_BIN - gh executable to invoke (default: gh), so tests can substitute
#            a recorder/mock in place of the real GitHub CLI.
set -euo pipefail

body_file="${1:?usage: comment.sh <markdown-file>}"
gh_bin="${GH_BIN:-gh}"
marker='<!-- dblift-action -->'
max_bytes=65000

marked_file="$RUNNER_TEMP/dblift-comment-marked.$$"
api_body_file="$RUNNER_TEMP/dblift-comment-api-body.$$"
trap 'rm -f "$marked_file" "$api_body_file"' EXIT

# --- 2. Prepend the marker to every body written ----------------------------

{
  printf '%s\n' "$marker"
  cat "$body_file"
} > "$marked_file"

# Writes the marker-prefixed body to the step summary (if configured) and
# exits 0. $1, if non-empty, is logged to stderr first.
fall_back_to_summary() {
  if [ -n "${1:-}" ]; then
    echo "$1" >&2
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$marked_file" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

# --- 1. Resolve the pull request number --------------------------------------

pr_number=""
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -r "$GITHUB_EVENT_PATH" ]; then
  pr_number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null) || pr_number=""
fi

if [ -z "$pr_number" ]; then
  fall_back_to_summary ""
fi

# --- A missing `gh` binary is not the same as a failing `gh` ----------------

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  fall_back_to_summary "comment.sh: '$gh_bin' not found; writing the plan to the step summary instead"
fi

# --- 5. Build the (possibly truncated) body used for the API call -----------
# Byte-measured, not character-measured: the rendered headings contain a
# real em dash, which is three bytes in UTF-8.

marked_size=$(wc -c < "$marked_file" | tr -d ' ')

if [ "$marked_size" -le "$max_bytes" ]; then
  cp "$marked_file" "$api_body_file"
else
  # Cut at a line boundary within max_bytes. Bytes, not characters: force
  # the C locale so awk's length() counts bytes rather than decoding
  # multi-byte characters, which also guarantees the cut never lands
  # inside one.
  LC_ALL=C awk -v max="$max_bytes" '
    { total += length($0) + 1
      if (total > max) exit
      print
    }
  ' "$marked_file" > "$api_body_file"

  # If the cut left a fence open, close it with a run of backticks at
  # least as long as the one that opened it -- scripts/plan-sql.sh sizes
  # fences to survive backtick content in SQL, so a shorter closing run
  # would not actually terminate the block.
  fence_len=0
  in_fence=0
  while IFS= read -r line; do
    if [ "$in_fence" -eq 0 ]; then
      if [[ "$line" =~ ^(\`{3,}) ]]; then
        fence_len=${#BASH_REMATCH[1]}
        in_fence=1
      fi
    elif [[ "$line" =~ ^\`+$ ]] && [ "${#line}" -ge "$fence_len" ]; then
      in_fence=0
    fi
  done < "$api_body_file"

  if [ "$in_fence" -eq 1 ]; then
    close=$(printf '%*s' "$fence_len" '' | tr ' ' '`')
    printf '%s\n' "$close" >> "$api_body_file"
  fi

  {
    echo
    echo "_Output truncated. See the job logs for the full migration plan._"
  } >> "$api_body_file"
fi

# --- 3. Find the existing comment --------------------------------------------

repo="$GITHUB_REPOSITORY"

if ! list_output=$("$gh_bin" api "repos/$repo/issues/$pr_number/comments" --paginate \
      --jq 'map(select(.body | contains("<!-- dblift-action -->"))) | .[0].id // empty' 2>&1); then
  fall_back_to_summary "comment.sh: gh api failed while listing comments: $list_output"
fi
comment_id="$list_output"

# --- 4. Update or create -----------------------------------------------------

if [ -n "$comment_id" ]; then
  if ! output=$("$gh_bin" api "repos/$repo/issues/comments/$comment_id" -X PATCH \
        --field "body=@$api_body_file" 2>&1); then
    fall_back_to_summary "comment.sh: gh api failed while updating comment $comment_id: $output"
  fi
else
  if ! output=$("$gh_bin" api "repos/$repo/issues/$pr_number/comments" -X POST \
        --field "body=@$api_body_file" 2>&1); then
    fall_back_to_summary "comment.sh: gh api failed while creating comment: $output"
  fi
fi

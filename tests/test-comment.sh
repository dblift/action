#!/bin/bash
# Verify scripts/comment.sh against the six cases from the task brief, plus
# two more: a missing `gh` binary (a gap identified in the brief, see the
# comment above the missing-gh case below) and a body containing a
# five-backtick fence, which must be closed with a matching five-backtick
# run rather than a hardcoded three.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
comment_script="$repo_root/scripts/comment.sh"
mock_gh="$repo_root/tests/mocks/gh"

tmp_root="$repo_root/tests/tmp/test-comment"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

marker='<!-- dblift-action -->'
notice='_Output truncated. See the job logs for the full migration plan._'

pr_event_file="$tmp_root/pr-event.json"
echo '{"pull_request": {"number": 7}}' > "$pr_event_file"

non_pr_event_file="$tmp_root/non-pr-event.json"
echo '{}' > "$non_pr_event_file"

small_body_file="$tmp_root/small-body.md"
{
  echo "### V1 -- add_users"
  echo
  echo '```sql'
  echo "CREATE TABLE users (id INTEGER PRIMARY KEY);"
  echo '```'
} > "$small_body_file"

# Runs scripts/comment.sh with the given body file, event file, repository,
# gh binary and GH_MODE. Sets LAST_EXIT, LAST_STDERR_FILE, LAST_SUMMARY_FILE,
# LAST_GH_LOG (one line per gh invocation) for the caller to assert on.
run_counter=0
run_comment() {
  local body_file="$1" event_file="$2" repo="$3" gh_bin="$4" gh_mode="$5"
  run_counter=$((run_counter + 1))

  local runner_temp="$tmp_root/runner-temp-$run_counter"
  mkdir -p "$runner_temp"
  LAST_SUMMARY_FILE="$tmp_root/summary-$run_counter"
  LAST_STDOUT_FILE="$tmp_root/stdout-$run_counter"
  LAST_STDERR_FILE="$tmp_root/stderr-$run_counter"
  LAST_GH_LOG="$tmp_root/gh-log-$run_counter"
  : > "$LAST_SUMMARY_FILE"
  : > "$LAST_GH_LOG"

  set +e
  env \
    RUNNER_TEMP="$runner_temp" \
    GITHUB_STEP_SUMMARY="$LAST_SUMMARY_FILE" \
    GITHUB_EVENT_PATH="$event_file" \
    GITHUB_REPOSITORY="$repo" \
    GITHUB_TOKEN="test-token" \
    GH_BIN="$gh_bin" \
    GH_LOG="$LAST_GH_LOG" \
    GH_MODE="$gh_mode" \
    bash "$comment_script" "$body_file" >"$LAST_STDOUT_FILE" 2>"$LAST_STDERR_FILE"
  LAST_EXIT=$?
  set -e
}

count_matching() {
  # Count GH_LOG lines matching a fixed substring (grep -F -c).
  grep -F -c -- "$1" "$2" 2>/dev/null || true
}

# --- Case 1: no existing comment -> exactly one POST, no PATCH -------------

run_comment "$small_body_file" "$pr_event_file" "octocat/dblift-action-test" "$mock_gh" "empty"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case1: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
post_count=$(count_matching "-X POST" "$LAST_GH_LOG")
patch_count=$(count_matching "-X PATCH" "$LAST_GH_LOG")
if [ "$post_count" -ne 1 ]; then
  fail "case1: expected exactly one POST, got $post_count (log: $(cat "$LAST_GH_LOG"))"
fi
if [ "$patch_count" -ne 0 ]; then
  fail "case1: expected no PATCH, got $patch_count (log: $(cat "$LAST_GH_LOG"))"
fi
if ! grep -q "issues/7/comments" "$LAST_GH_LOG"; then
  fail "case1: expected the POST to target issues/7/comments (log: $(cat "$LAST_GH_LOG"))"
fi
# --- The list call must actually filter on the marker, not just report a --
# plausible id because $GH_MODE said so. tests/mocks/gh decides its canned
# response purely from the presence of --jq in argv (see its header); it
# never evaluates the filter. Without this check, a wrong or missing
# marker in the jq expression -- which would make the real gh always
# return an unfiltered .[0] and post a new comment on every push, the
# exact bug this task exists to prevent -- would not fail any test here.
list_call_line=$(grep -F -- "--jq" "$LAST_GH_LOG" || true)
if [ -z "$list_call_line" ]; then
  fail "case1: expected the list call to be logged with --jq"
else
  if ! grep -qF -- "$marker" <<< "$list_call_line"; then
    fail "case1: expected the list call's jq filter to reference the marker '$marker', got: $list_call_line"
  fi
  if ! grep -qF -- "select(.body" <<< "$list_call_line"; then
    fail "case1: expected the list call's jq filter to select on .body rather than blindly take the first comment, got: $list_call_line"
  fi
fi
# --- Case 3 (part 1): marker present in the posted body ---------------------
if [ ! -f "$LAST_GH_LOG.body" ]; then
  fail "case1: expected the mock to have captured a posted body"
else
  first_line=$(head -n1 "$LAST_GH_LOG.body")
  if [ "$first_line" != "$marker" ]; then
    fail "case1: expected the posted body to start with the marker, got '$first_line'"
  fi
fi

# --- Case 2: existing comment (id 4242) -> exactly one PATCH, no POST ------

run_comment "$small_body_file" "$pr_event_file" "octocat/dblift-action-test" "$mock_gh" "existing"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case2: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
post_count=$(count_matching "-X POST" "$LAST_GH_LOG")
patch_count=$(count_matching "-X PATCH" "$LAST_GH_LOG")
if [ "$patch_count" -ne 1 ]; then
  fail "case2: expected exactly one PATCH, got $patch_count (log: $(cat "$LAST_GH_LOG"))"
fi
if [ "$post_count" -ne 0 ]; then
  fail "case2: expected no POST, got $post_count (log: $(cat "$LAST_GH_LOG"))"
fi
if ! grep -q "issues/comments/4242" "$LAST_GH_LOG"; then
  fail "case2: expected the PATCH to target issues/comments/4242 (log: $(cat "$LAST_GH_LOG"))"
fi
# --- Case 3 (part 2): marker present in the updated body --------------------
if [ ! -f "$LAST_GH_LOG.body" ]; then
  fail "case2: expected the mock to have captured a posted body"
else
  first_line=$(head -n1 "$LAST_GH_LOG.body")
  if [ "$first_line" != "$marker" ]; then
    fail "case2: expected the posted body to start with the marker, got '$first_line'"
  fi
fi

# --- Case 4: oversized body -> truncated, notice present, fences balanced --

oversized_body_file="$tmp_root/oversized-body.md"
{
  echo "## Migration Plan"
  echo
  echo '```sql'
  i=0
  while [ "$i" -lt 6000 ]; do
    echo "SELECT $i;"
    i=$((i + 1))
  done
  echo '```'
} > "$oversized_body_file"

oversized_size=$(wc -c < "$oversized_body_file" | tr -d ' ')
if [ "$oversized_size" -le 65000 ]; then
  fail "case4: test fixture is not actually oversized ($oversized_size bytes)"
fi

run_comment "$oversized_body_file" "$pr_event_file" "octocat/dblift-action-test" "$mock_gh" "empty"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case4: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
posted_body="$LAST_GH_LOG.body"
if [ ! -f "$posted_body" ]; then
  fail "case4: expected the mock to have captured a posted body"
else
  posted_size=$(wc -c < "$posted_body" | tr -d ' ')
  if [ "$posted_size" -gt 65200 ]; then
    fail "case4: expected the truncated body to be near the 65000-byte threshold, got $posted_size bytes"
  fi
  if ! grep -qF "$notice" "$posted_body"; then
    fail "case4: expected the truncation notice in the posted body"
  fi
  last_line=$(tail -n1 "$posted_body")
  if [ "$last_line" != "$notice" ]; then
    fail "case4: expected the notice to be the last line, got '$last_line'"
  fi
  fence_line_count=$(grep -c -E '^`{3,}(sql)?$' "$posted_body" || true)
  if [ "$((fence_line_count % 2))" -ne 0 ]; then
    fail "case4: expected an even number of fence marker lines, got $fence_line_count"
  fi
fi

# --- Case 5: gh failure -> exits 0, step summary carries the body, stderr --
# explains it.

run_comment "$small_body_file" "$pr_event_file" "octocat/dblift-action-test" "$mock_gh" "fail"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case5: expected exit 0, got $LAST_EXIT"
fi
if ! grep -qF "$(head -n1 "$small_body_file")" "$LAST_SUMMARY_FILE"; then
  fail "case5: expected the step summary to contain the body"
fi
if ! grep -q "gh api failed" "$LAST_STDERR_FILE"; then
  fail "case5: expected stderr to explain the gh failure, got: $(cat "$LAST_STDERR_FILE")"
fi

# --- Case 6: not a pull request -> exit 0, summary carries the body, gh is -
# never invoked.

run_comment "$small_body_file" "$non_pr_event_file" "octocat/dblift-action-test" "$mock_gh" "empty"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case6: expected exit 0, got $LAST_EXIT"
fi
if ! grep -qF "$(head -n1 "$small_body_file")" "$LAST_SUMMARY_FILE"; then
  fail "case6: expected the step summary to contain the body"
fi
if [ -s "$LAST_GH_LOG" ]; then
  fail "case6: expected gh to never be invoked, log was: $(cat "$LAST_GH_LOG")"
fi

# --- Case 7: missing gh binary -> not the same as a failing gh. exit 0, ----
# stderr explains it, step summary carries the body, gh is never invoked.
# (Gap identified ahead of implementation: the brief's "any gh failure
# degrades gracefully" covers a non-zero exit, but an absent gh binary is
# "command not found" under set -e, which would otherwise kill the script
# before it reaches that fallback.)

missing_gh="$tmp_root/no-such-gh-binary"

run_comment "$small_body_file" "$pr_event_file" "octocat/dblift-action-test" "$missing_gh" "empty"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case7: expected exit 0, got $LAST_EXIT"
fi
if ! grep -qF "$(head -n1 "$small_body_file")" "$LAST_SUMMARY_FILE"; then
  fail "case7: expected the step summary to contain the body"
fi
if ! grep -q "not found" "$LAST_STDERR_FILE"; then
  fail "case7: expected stderr to explain the missing gh binary, got: $(cat "$LAST_STDERR_FILE")"
fi
if [ -s "$LAST_GH_LOG" ]; then
  fail "case7: expected gh to never be invoked, log was: $(cat "$LAST_GH_LOG")"
fi

# --- Case 8: a five-backtick fence straddling the truncation cut must be --
# closed with a matching five-backtick run, not a hardcoded three.
# scripts/plan-sql.sh sizes fences to survive backtick content in SQL (see
# its own header comment); a truncation that closes with fewer backticks
# than the opening run does not terminate the block, per CommonMark.

fivebacktick_body_file="$tmp_root/fivebacktick-body.md"
{
  echo "## Comment example"
  echo
  echo '`````sql'
  i=0
  while [ "$i" -lt 6000 ]; do
    echo "SELECT $i;"
    i=$((i + 1))
  done
  echo '`````'
} > "$fivebacktick_body_file"

run_comment "$fivebacktick_body_file" "$pr_event_file" "octocat/dblift-action-test" "$mock_gh" "empty"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case8: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
posted_body="$LAST_GH_LOG.body"
if [ ! -f "$posted_body" ]; then
  fail "case8: expected the mock to have captured a posted body"
else
  if ! grep -qF "$notice" "$posted_body"; then
    fail "case8: expected the truncation notice in the posted body"
  fi
  # The closing fence line is the one immediately before the blank line
  # that precedes the notice.
  closing_line=$(tail -n3 "$posted_body" | head -n1)
  if [[ ! "$closing_line" =~ ^\`{5,}$ ]]; then
    fail "case8: expected a closing fence of at least 5 backticks, got '$closing_line'"
  fi
fi

if [ "$failures" -eq 0 ]; then
  echo "test-comment.sh: all cases passed"
fi

exit "$failures"

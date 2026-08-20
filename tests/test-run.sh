#!/bin/bash
# Verify scripts/run.sh against the cases from the task brief, using SQLite
# fixtures and fake GITHUB_OUTPUT / GITHUB_STEP_SUMMARY / RUNNER_TEMP files
# under tests/tmp/.
#
# run.sh no longer installs anything (scripts/install.sh owns that, covered by
# tests/test-install.sh), so these cases require a working `dblift` on PATH.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
run_script="$repo_root/scripts/run.sh"

tmp_root="$repo_root/tests/tmp/test-run"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# The canonical SQLite fixture project lives in tests/fixtures/project (the
# same one the smoke jobs consume); copying it instead of re-declaring it here
# keeps a schema change from silently testing a different project.
setup_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cp -r "$repo_root/tests/fixtures/project/." "$dir/"
}

run_counter=0

# Runs scripts/run.sh with the given working directory, command and args.
# The optional 4th argument overrides the dblift binary via run.sh's
# DBLIFT_BIN hook. Sets LAST_EXIT, LAST_STDOUT_FILE, LAST_STDERR_FILE,
# LAST_OUTPUT_FILE, LAST_SUMMARY_FILE and LAST_RUNNER_TEMP for the caller to
# assert on.
run_case() {
  local working_dir="$1" command="$2" args="$3" dblift_bin="${4:-dblift}"
  run_counter=$((run_counter + 1))

  LAST_RUNNER_TEMP="$tmp_root/runner-temp-$run_counter"
  mkdir -p "$LAST_RUNNER_TEMP"
  LAST_OUTPUT_FILE="$tmp_root/github-output-$run_counter"
  LAST_SUMMARY_FILE="$tmp_root/github-summary-$run_counter"
  LAST_STDOUT_FILE="$tmp_root/stdout-$run_counter"
  LAST_STDERR_FILE="$tmp_root/stderr-$run_counter"
  : > "$LAST_OUTPUT_FILE"
  : > "$LAST_SUMMARY_FILE"

  set +e
  env \
    INPUT_COMMAND="$command" \
    INPUT_ARGS="$args" \
    INPUT_WORKING_DIRECTORY="$working_dir" \
    INPUT_ENV_NAME="" \
    INPUT_SUMMARY="true" \
    GITHUB_OUTPUT="$LAST_OUTPUT_FILE" \
    GITHUB_STEP_SUMMARY="$LAST_SUMMARY_FILE" \
    RUNNER_TEMP="$LAST_RUNNER_TEMP" \
    DBLIFT_BIN="$dblift_bin" \
    bash "$run_script" >"$LAST_STDOUT_FILE" 2>"$LAST_STDERR_FILE"
  LAST_EXIT=$?
  set -e
}

get_output() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" | tail -n1 | cut -d= -f2-
}

# --- Case 1: clean history -> migrate succeeds, pending-count is 0 ---------
# dblift's own migrate runs a validation pre-flight and aborts on a bad
# checksum or ordering, so applying to an ephemeral CI database IS the check.

case1_dir="$tmp_root/case1"
setup_fixture "$case1_dir"
run_case "$case1_dir" migrate ""

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case1: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "0" ]; then
  fail "case1: expected pending-count=0, got '$pending'"
fi

# Global Constraint 4: run.sh must never write into the caller's workspace.
# The merged-output capture belongs under $RUNNER_TEMP and nowhere else.
if [ ! -s "$LAST_RUNNER_TEMP/dblift-run-output.log" ]; then
  fail "case1: expected a non-empty output capture at \$RUNNER_TEMP/dblift-run-output.log (contents of \$RUNNER_TEMP: $(ls -A "$LAST_RUNNER_TEMP" 2>&1))"
fi
stray=$(find "$case1_dir" -name 'dblift-run-output.log' -print 2>/dev/null)
if [ -n "$stray" ]; then
  fail "case1: run.sh wrote its output capture into the working directory: $stray"
fi

# dblift's own file log defaults to a relative ./logs; run.sh must reroute it
# under $RUNNER_TEMP so nothing lands in the caller's checkout.
if [ -d "$case1_dir/logs" ]; then
  fail "case1: dblift wrote a logs/ directory into the working directory"
fi

# The step summary must report the command, exit status, pending count and
# the captured output.
for heading in '### dblift' '**Command:**' '**Exit status:** 0' '**Pending migrations:** 0' '**Output:**'; do
  if ! grep -qF -- "$heading" "$LAST_SUMMARY_FILE"; then
    fail "case1: expected the step summary to contain '$heading' (summary: $(cat "$LAST_SUMMARY_FILE"))"
  fi
done

# --- Case 2: fresh database -> info succeeds, pending-count is 2 -----------

case2_dir="$tmp_root/case2"
setup_fixture "$case2_dir"
run_case "$case2_dir" info ""

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case2: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "2" ]; then
  fail "case2: expected pending-count=2, got '$pending'"
fi

# --- Case 3: modified migration -> validate exits 1 -------------------------

case3_dir="$tmp_root/case3"
setup_fixture "$case3_dir"
run_case "$case3_dir" migrate ""
if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case3: setup migrate expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi

echo "-- modified after apply" >> "$case3_dir/migrations/V1__create_users.sql"

run_case "$case3_dir" validate ""
if [ "$LAST_EXIT" -ne 1 ]; then
  fail "case3: expected exit 1, got $LAST_EXIT"
fi

# --- Case 4: unknown command -> non-zero exit, valid values listed ---------

case4_dir="$tmp_root/case4"
setup_fixture "$case4_dir"
run_case "$case4_dir" bogus ""

if [ "$LAST_EXIT" -eq 0 ]; then
  fail "case4: expected non-zero exit, got 0"
fi
for value in migrate validate info; do
  if ! grep -q "$value" "$LAST_STDERR_FILE"; then
    fail "case4: expected stderr to mention '$value' (stderr: $(cat "$LAST_STDERR_FILE"))"
  fi
done

# --- Case 4b: the removed `check` alias is now rejected like any unknown ----
# `check` ran migrate, then validate, then info. dblift's migrate already
# validates as a pre-flight, and pending-count is computed from this script's
# own `info --format json` probe regardless of the command, so every step
# after the first was redundant. It must not silently keep working.

run_case "$case4_dir" check ""

if [ "$LAST_EXIT" -ne 2 ]; then
  fail "case4b: expected the removed 'check' alias to be rejected with exit 2, got $LAST_EXIT"
fi
if ! grep -q 'unknown command' "$LAST_STDERR_FILE"; then
  fail "case4b: expected 'check' to be reported as an unknown command (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
if grep -q "valid values:.*check" "$LAST_STDERR_FILE"; then
  fail "case4b: 'check' is still advertised as a valid value (stderr: $(cat "$LAST_STDERR_FILE"))"
fi

# --- Case 4c: no command and no args -> exit 2 naming both ways out --------
# `command` has no default, so the Action never applies migrations the caller
# did not ask for. Because args-only usage is valid, this cannot be enforced
# by making the input required; it is enforced here instead.

run_case "$case4_dir" "" ""

if [ "$LAST_EXIT" -ne 2 ]; then
  fail "case4c: expected exit 2 when neither command nor args is set, got $LAST_EXIT"
fi
for expected in migrate validate info args; do
  if ! grep -q "$expected" "$LAST_STDERR_FILE"; then
    fail "case4c: expected stderr to mention '$expected' (stderr: $(cat "$LAST_STDERR_FILE"))"
  fi
done

# The exit-code output is part of the contract on every path: a consumer
# following the README's continue-on-error recipe must read the status even
# when the script bailed before running dblift.
exit_code_out=$(get_output "$LAST_OUTPUT_FILE" exit-code)
if [ "$exit_code_out" != "2" ]; then
  fail "case4c: expected the exit-code output to be written as 2 on the early-exit path, got '$exit_code_out'"
fi

# --- Case 4d: no command but args set -> runs normally ---------------------
# args-only usage is exactly why `command` cannot be marked required. The
# pending-count probe is skipped in args mode (it cannot replicate raw
# arguments), so the output must be empty and the skip must be logged.

run_case "$case4_dir" "" "info"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case4d: args-only usage must run without a command, got exit $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "" ]; then
  fail "case4d: expected pending-count to be empty in args mode, got '$pending'"
fi
if ! grep -q "pending-count is not computed" "$LAST_STDERR_FILE"; then
  fail "case4d: expected stderr to explain the skipped probe (stderr: $(cat "$LAST_STDERR_FILE"))"
fi

# --- Case 5: args overrides command -> JSON on stdout, no migration applied

case5_dir="$tmp_root/case5"
setup_fixture "$case5_dir"
run_case "$case5_dir" migrate "info --format json"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case5: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
if ! awk '/^\{$/,0' "$LAST_STDOUT_FILE" | jq -e '.migrations' > /dev/null 2>&1; then
  fail "case5: expected valid JSON with a migrations field on stdout"
fi
# pending-count is empty in args mode, so prove nothing was applied with a
# follow-up command-mode run against the same fixture.
run_case "$case5_dir" info ""
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "2" ]; then
  fail "case5: expected pending-count=2 (no migration applied), got '$pending'"
fi

# --- Case 6: whitespace-only args -> falls through to command dispatch -----
# Tokenizing whitespace-only input yields zero arguments; expanding an empty
# array under `set -u` on bash 3.2 (the macOS-runner version) aborts with
# "unbound variable" unless the empty-result case is handled, and the script
# must fall back to command dispatch rather than invoking dblift bare.

case6_dir="$tmp_root/case6"
setup_fixture "$case6_dir"
run_case "$case6_dir" info " "

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case6: expected exit 0 (whitespace-only args must fall back to command dispatch, not crash), got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "2" ]; then
  fail "case6: expected pending-count=2, got '$pending'"
fi

# --- Case 7: Global Constraint 3 -- dblift's stderr is always surfaced -----
# A stub standing in for dblift writes a unique marker to stderr. run.sh
# merges stderr into the stream it tees, so the marker must reach both the
# caller's console and the captured output. Discarding or swallowing dblift's
# stderr anywhere in run.sh turns this red.

stderr_stub="$tmp_root/dblift-stderr-stub.sh"
cat > "$stderr_stub" <<'STUB'
#!/bin/bash
echo "DBLIFT_STDERR_MARKER_7f3a" >&2
# The pending-count probe calls `info --format json`; answer it with a
# well-formed payload so the probe stays on its normal path. The subcommand
# is scanned for rather than read from $1: run.sh prepends global flags
# (--log-dir) ahead of it.
for arg in "$@"; do
  if [ "$arg" = "info" ]; then
    echo '{'
    echo '  "migrations": [{"version": "1", "status": "PENDING"}]'
    echo '}'
    break
  fi
done
STUB
chmod +x "$stderr_stub"

case7_dir="$tmp_root/case7"
setup_fixture "$case7_dir"
run_case "$case7_dir" migrate "" "$stderr_stub"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case7: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
if ! grep -qF 'DBLIFT_STDERR_MARKER_7f3a' "$LAST_STDOUT_FILE"; then
  fail "case7: dblift's stderr was not surfaced to the caller (stdout: $(cat "$LAST_STDOUT_FILE"))"
fi
if ! grep -qF 'DBLIFT_STDERR_MARKER_7f3a' "$LAST_RUNNER_TEMP/dblift-run-output.log"; then
  fail "case7: dblift's stderr was not captured into the output log"
fi
if ! grep -qF 'DBLIFT_STDERR_MARKER_7f3a' "$LAST_SUMMARY_FILE"; then
  fail "case7: dblift's stderr did not reach the step summary"
fi

# --- Case 8: the step summary fences are sized to their content ------------
# dblift's output is arbitrary text and `args` comes from the caller, so
# either can contain a Markdown fence. A fixed three-backtick fence is closed
# early by such content, and the rest of the output escapes the code block.
# Same defect class as the one fixed in plan-sql.sh and comment.sh.

fence_stub="$tmp_root/dblift-fence-stub.sh"
cat > "$fence_stub" <<'STUB'
#!/bin/bash
# The subcommand is scanned for rather than read from $1: run.sh prepends
# global flags (--log-dir) ahead of it.
for arg in "$@"; do
  if [ "$arg" = "info" ]; then
    echo '{'
    echo '  "migrations": []'
    echo '}'
    exit 0
  fi
done
echo 'before the fence'
echo '````'
echo 'after the fence'
STUB
chmod +x "$fence_stub"

case8_dir="$tmp_root/case8"
setup_fixture "$case8_dir"
run_case "$case8_dir" migrate "" "$fence_stub"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case8: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi

# The captured output holds a run of 4 backticks, so the fence wrapping it
# must be at least 5 -- a 3- or 4-backtick fence would be closed by it.
if grep -qx '````' "$LAST_SUMMARY_FILE" && ! grep -qx '`````' "$LAST_SUMMARY_FILE"; then
  fail "case8: the step summary fence was not sized to its content; a 4-backtick line in dblift's output escapes the code block (summary: $(cat "$LAST_SUMMARY_FILE"))"
fi
if ! grep -qx '`````' "$LAST_SUMMARY_FILE"; then
  fail "case8: expected a 5-backtick fence around output containing a 4-backtick line (summary: $(cat "$LAST_SUMMARY_FILE"))"
fi

# The content itself must survive intact on both sides of the embedded fence.
for line in 'before the fence' 'after the fence'; do
  if ! grep -qxF -- "$line" "$LAST_SUMMARY_FILE"; then
    fail "case8: expected '$line' in the step summary"
  fi
done

# --- Case 9: args is split like a shell command line ------------------------
# A quoted argument containing spaces must reach dblift as one token, with
# the quote characters stripped. The recording stub writes each argument on
# its own line under $RUNNER_TEMP, where run_case already points RUNNER_TEMP.

argv_stub="$tmp_root/dblift-argv-stub.sh"
cat > "$argv_stub" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$RUNNER_TEMP/dblift-argv.log"
STUB
chmod +x "$argv_stub"

case9_dir="$tmp_root/case9"
setup_fixture "$case9_dir"
run_case "$case9_dir" "" 'migrate --description "add users table"' "$argv_stub"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case9: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
if ! grep -qxF -- 'add users table' "$LAST_RUNNER_TEMP/dblift-argv.log"; then
  fail "case9: expected 'add users table' to reach dblift as a single unquoted token (argv: $(tr '\n' '|' < "$LAST_RUNNER_TEMP/dblift-argv.log"))"
fi
if grep -qF -- '"' "$LAST_RUNNER_TEMP/dblift-argv.log"; then
  fail "case9: quote characters leaked into dblift's argv (argv: $(tr '\n' '|' < "$LAST_RUNNER_TEMP/dblift-argv.log"))"
fi

# --- Case 9b: an unbalanced quote in args fails loudly ----------------------
# Silent corruption of the command line is the failure mode being replaced;
# a parse error must exit 2 before dblift is ever invoked.

run_case "$case9_dir" "" 'migrate --description "unbalanced' "$argv_stub"

if [ "$LAST_EXIT" -ne 2 ]; then
  fail "case9b: expected exit 2 on an unbalanced quote in args, got $LAST_EXIT"
fi
if ! grep -q "could not parse 'args'" "$LAST_STDERR_FILE"; then
  fail "case9b: expected stderr to explain the parse failure (stderr: $(cat "$LAST_STDERR_FILE"))"
fi

if [ "$failures" -eq 0 ]; then
  echo "test-run.sh: all cases passed"
fi

exit "$failures"

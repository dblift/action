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

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/migrations"
  cat > "$dir/migrations/V1__create_users.sql" <<'SQL'
CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
SQL
  cat > "$dir/migrations/V2__add_index.sql" <<'SQL'
CREATE INDEX idx_users_email ON users(email);
ALTER TABLE users ADD COLUMN name TEXT;
SQL
  cat > "$dir/dblift.yml" <<'YAML'
database:
  type: sqlite
  url: "sqlite:///test.db"
migrations:
  directories: [migrations]
YAML
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

# --- Case 1: clean history -> check succeeds, pending-count is 0 -----------

case1_dir="$tmp_root/case1"
setup_fixture "$case1_dir"
run_case "$case1_dir" check ""

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
for value in migrate validate info check; do
  if ! grep -q "$value" "$LAST_STDERR_FILE"; then
    fail "case4: expected stderr to mention '$value' (stderr: $(cat "$LAST_STDERR_FILE"))"
  fi
done

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
pending=$(get_output "$LAST_OUTPUT_FILE" pending-count)
if [ "$pending" != "2" ]; then
  fail "case5: expected pending-count=2 (no migration applied), got '$pending'"
fi

# --- Case 6: whitespace-only args -> falls through to command dispatch -----
# Regression test: `read -ra` on whitespace-only input yields a zero-element
# array; expanding that under `set -u` on bash 3.2 (the macOS-runner version)
# aborts with "unbound variable" unless the empty-result case is handled.

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
# well-formed payload so the probe stays on its normal path.
if [ "${1:-}" = "info" ]; then
  echo '{'
  echo '  "migrations": [{"version": "1", "status": "PENDING"}]'
  echo '}'
fi
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

if [ "$failures" -eq 0 ]; then
  echo "test-run.sh: all cases passed"
fi

exit "$failures"

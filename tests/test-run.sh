#!/bin/bash
# Verify scripts/run.sh against the five cases from the task brief, using
# SQLite fixtures and fake GITHUB_OUTPUT / GITHUB_STEP_SUMMARY / RUNNER_TEMP
# files under tests/tmp/.
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

# A wrapper around the real dblift binary: this dev machine carries stale
# extension metadata that makes dblift abort at import unless CLI extensions
# are disabled. DBLIFT_DISABLE_CLI_EXTENSIONS is a local workaround for that
# and must never appear in scripts/run.sh itself.
dblift_wrapper="$tmp_root/dblift-wrapper.sh"
cat > "$dblift_wrapper" <<'WRAP'
#!/bin/bash
export DBLIFT_DISABLE_CLI_EXTENSIONS=1
exec dblift "$@"
WRAP
chmod +x "$dblift_wrapper"

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

# Runs scripts/run.sh with the given working directory, command, args and
# (optionally) packages. Sets LAST_EXIT, LAST_STDOUT_FILE, LAST_STDERR_FILE,
# LAST_OUTPUT_FILE, LAST_SUMMARY_FILE for the caller to assert on.
run_case() {
  local working_dir="$1" command="$2" args="$3" packages="${4:-}"
  run_counter=$((run_counter + 1))

  local runner_temp="$tmp_root/runner-temp-$run_counter"
  mkdir -p "$runner_temp"
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
    INPUT_PACKAGES="$packages" \
    INPUT_VERSION="" \
    INPUT_EXTRAS="" \
    INPUT_WORKING_DIRECTORY="$working_dir" \
    INPUT_ENV_NAME="" \
    INPUT_INDEX_URL="" \
    INPUT_SUMMARY="true" \
    GITHUB_OUTPUT="$LAST_OUTPUT_FILE" \
    GITHUB_STEP_SUMMARY="$LAST_SUMMARY_FILE" \
    RUNNER_TEMP="$runner_temp" \
    DBLIFT_BIN="$dblift_wrapper" \
    DBLIFT_SKIP_INSTALL=1 \
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

# --- Case 7: whitespace-only packages -> falls back to the extras specifier

case7_dir="$tmp_root/case7"
setup_fixture "$case7_dir"
run_case "$case7_dir" info "" " "

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case7: expected exit 0 (whitespace-only packages must fall back to extras, not crash), got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
if ! grep -q '^Installing: dblift\[' "$LAST_STDOUT_FILE"; then
  fail "case7: expected whitespace-only packages to fall back to the extras-based specifier (stdout: $(cat "$LAST_STDOUT_FILE"))"
fi

if [ "$failures" -eq 0 ]; then
  echo "test-run.sh: all cases passed"
fi

exit "$failures"

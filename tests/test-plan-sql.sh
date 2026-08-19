#!/bin/bash
# Verify scripts/plan-sql.sh against the five cases from the task brief.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
plan_script="$repo_root/scripts/plan-sql.sh"
fixtures_dir="$repo_root/tests/fixtures"

tmp_root="$repo_root/tests/tmp/test-plan-sql"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# --- Case 1: fixture rendering -> matches the expected Markdown exactly ----

case1_out="$tmp_root/case1-actual.md"
bash "$plan_script" "$fixtures_dir/plan.json" > "$case1_out"

if ! diff -u "$fixtures_dir/plan-expected.md" "$case1_out" > "$tmp_root/case1.diff"; then
  fail "case1: rendered output does not match expected fixture ($(cat "$tmp_root/case1.diff"))"
fi

# --- Case 2: empty plan -> no-migrations sentence --------------------------

case2_out="$tmp_root/case2-actual.md"
set +e
bash "$plan_script" "$fixtures_dir/plan-empty.json" > "$case2_out"
case2_exit=$?
set -e

if [ "$case2_exit" -ne 0 ]; then
  fail "case2: expected exit 0, got $case2_exit"
fi
expected_sentence="_No pending migrations — nothing to apply._"
actual_sentence=$(cat "$case2_out")
if [ "$actual_sentence" != "$expected_sentence" ]; then
  fail "case2: expected sentence '$expected_sentence', got '$actual_sentence'"
fi

# --- Case 3: missing sql key -> same sentence, exit 0 ----------------------

case3_out="$tmp_root/case3-actual.md"
set +e
bash "$plan_script" "$fixtures_dir/plan-no-sql-key.json" > "$case3_out"
case3_exit=$?
set -e

if [ "$case3_exit" -ne 0 ]; then
  fail "case3: expected exit 0, got $case3_exit"
fi
actual_sentence=$(cat "$case3_out")
if [ "$actual_sentence" != "$expected_sentence" ]; then
  fail "case3: expected sentence '$expected_sentence', got '$actual_sentence'"
fi

# --- Case 4: end-to-end against the real dblift binary ---------------------
# This dev machine carries stale extension metadata that makes dblift abort
# at import unless CLI extensions are disabled. DBLIFT_DISABLE_CLI_EXTENSIONS
# is a local test workaround only and must never appear in scripts/plan-sql.sh.

case4_dir="$tmp_root/case4"
mkdir -p "$case4_dir/migrations" "$case4_dir/logs"
cat > "$case4_dir/migrations/V1__create_users.sql" <<'SQL'
CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
SQL
cat > "$case4_dir/migrations/V2__add_index.sql" <<'SQL'
CREATE INDEX idx_users_email ON users(email);
ALTER TABLE users ADD COLUMN name TEXT;
SQL
cat > "$case4_dir/dblift.yml" <<'YAML'
database:
  type: sqlite
  url: "sqlite:///test.db"
migrations:
  directories: [migrations]
YAML

case4_log="$case4_dir/logs/plan.json"

set +e
(
  cd "$case4_dir"
  export DBLIFT_DISABLE_CLI_EXTENSIONS=1
  dblift --log-format json --log-dir "$case4_dir/logs" --log-file plan.json \
         migrate --dry-run --show-sql
)
case4_dblift_exit=$?
set -e

if [ "$case4_dblift_exit" -ne 0 ]; then
  fail "case4: dblift dry-run exited $case4_dblift_exit"
fi

if [ ! -f "$case4_log" ]; then
  fail "case4: expected log file at $case4_log, none was produced"
else
  case4_out="$tmp_root/case4-actual.md"
  bash "$plan_script" "$case4_log" > "$case4_out"

  if ! grep -q '### V1 — create_users' "$case4_out"; then
    fail "case4: expected output to contain the V1 heading (output: $(cat "$case4_out"))"
  fi
  if ! grep -q '### V2 — add_index' "$case4_out"; then
    fail "case4: expected output to contain the V2 heading (output: $(cat "$case4_out"))"
  fi
  if ! grep -q 'CREATE TABLE users' "$case4_out"; then
    fail "case4: expected output to contain the CREATE TABLE statement (output: $(cat "$case4_out"))"
  fi
fi

# --- Case 5: SQL fence integrity -> even number of fence markers -----------

fence_count=$(grep -c '^```' "$case1_out")
if [ "$((fence_count % 2))" -ne 0 ]; then
  fail "case5: expected an even number of fence markers in case1 output, got $fence_count"
fi

if [ -f "${case4_out:-}" ]; then
  fence_count=$(grep -c '^```' "$case4_out")
  if [ "$((fence_count % 2))" -ne 0 ]; then
    fail "case5: expected an even number of fence markers in case4 output, got $fence_count"
  fi
fi

if [ "$failures" -eq 0 ]; then
  echo "test-plan-sql.sh: all cases passed"
fi

exit "$failures"

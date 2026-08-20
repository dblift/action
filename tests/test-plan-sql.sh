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

# --- Case 5: SQL fence integrity -> a statement containing embedded ```    -
# and ```` lines must not terminate the fence early. A naive even-marker-
# count check cannot catch this (a prematurely closed fence plus a stray
# reopened one still totals an even count), so this instead parses the
# rendered output the way CommonMark would: find the opening fence line
# (`+sql), then the first later line composed only of backticks whose
# length is >= the opening fence's length closes the block. That must be
# the true end of the statement content, not an embedded backtick line.

# Prints the body between the first `...sql opening fence of exactly
# $2 backticks and the first qualifying closing fence in $1.
extract_fenced_block() {
  local file="$1" fence_len="$2"
  local open_pattern="^\`{${fence_len}}sql\$"
  local opened=0
  local line
  while IFS= read -r line; do
    if [ "$opened" -eq 0 ]; then
      if [[ "$line" =~ $open_pattern ]]; then
        opened=1
      fi
      continue
    fi
    if [[ "$line" =~ ^\`+$ ]] && [ "${#line}" -ge "$fence_len" ]; then
      return 0
    fi
    printf '%s\n' "$line"
  done < "$file"
}

backtick_fixture="$fixtures_dir/plan-backtick-fence.json"
case5_out="$tmp_root/case5-actual.md"
bash "$plan_script" "$backtick_fixture" > "$case5_out"

max_run=$(jq -r '[.sql[0].statements[] | [scan("`+")] | map(length) | (max // 0)] | max // 0' "$backtick_fixture")
opening_line=$(grep -m1 -E '^`{3,}sql$' "$case5_out" || true)
if [ -z "$opening_line" ]; then
  fail "case5: expected output to contain an opening sql fence, got: $(cat "$case5_out")"
else
  fence_len=$(( ${#opening_line} - 3 ))
  if [ "$fence_len" -le "$max_run" ]; then
    fail "case5: expected opening fence ($fence_len backticks) to be longer than the longest backtick run in the content ($max_run), got fence_len=$fence_len max_run=$max_run"
  fi

  expected_body=$(jq -r '.sql[0].statements | join("\n")' "$backtick_fixture")
  actual_body=$(extract_fenced_block "$case5_out" "$fence_len")
  if [ "$actual_body" != "$expected_body" ]; then
    fail "case5: fenced block content did not match the statement content (fence closed early) -- expected: [$expected_body] got: [$actual_body]"
  fi
fi

# Case 1's ordinary output (no embedded backticks) must still round-trip
# through the same fence-aware parser.
case1_max_run=0
case1_opening_line=$(grep -m1 -E '^`{3,}sql$' "$case1_out" || true)
if [ -z "$case1_opening_line" ]; then
  fail "case5: expected case1 output to contain an opening sql fence"
else
  case1_fence_len=$(( ${#case1_opening_line} - 3 ))
  case1_expected_body=$(jq -r '.sql[0].statements | join("\n")' "$fixtures_dir/plan.json")
  case1_actual_body=$(extract_fenced_block "$case1_out" "$case1_fence_len")
  if [ "$case1_actual_body" != "$case1_expected_body" ]; then
    fail "case5: case1 fenced block content did not match the statement content"
  fi
fi

if [ "$failures" -eq 0 ]; then
  echo "test-plan-sql.sh: all cases passed"
fi

exit "$failures"

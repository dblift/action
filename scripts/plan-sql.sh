#!/bin/bash
# Render the dry-run migration plan from dblift's JSON log as Markdown.
#
# Usage: plan-sql.sh <json-log-path>
#
# Reads the top-level `.sql` array from the JSON log file produced by:
#   dblift --log-format json --log-dir DIR --log-file NAME \
#          migrate --dry-run --show-sql
# (the identical payload under `.commands[].sql` is ignored). Writes Markdown
# to stdout: one `### V<version> — <description>` section per migration,
# each followed by a ```sql fenced block of its statements. Falls back to
# `script` for the heading when `description` is empty or absent. Emits a
# single sentence when `.sql` is absent or empty.
#
# Each section's fence is sized to be one backtick longer than the longest
# run of consecutive backticks found in that migration's statements (never
# shorter than 3), per CommonMark's fenced-code-block rule: a fence is only
# closed by a run of backticks at least as long as the one that opened it.
# This defends against SQL content (e.g. a COMMENT or string literal) that
# itself contains a backtick fence, without needing to escape the SQL.
set -euo pipefail

log_path="${1:?usage: plan-sql.sh <json-log-path>}"

sql_count=$(jq '(.sql // []) | length' "$log_path")

if [ "$sql_count" -eq 0 ]; then
  echo "_No pending migrations — nothing to apply._"
  exit 0
fi

jq -r '
  [
    (.sql // [])[]
    | (if ((.description // "") | length) > 0 then .description else .script end) as $heading
    | (.statements) as $stmts
    | ([$stmts[] | [scan("`+")] | map(length) | (max // 0)] | max // 0) as $max_run
    | ([3, ($max_run + 1)] | max) as $fence_len
    | ("`" * $fence_len) as $fence
    | "### V\(.version) — \($heading)\n\n" + $fence + "sql\n" + ($stmts | join("\n")) + "\n" + $fence
  ] | join("\n\n")
' "$log_path"

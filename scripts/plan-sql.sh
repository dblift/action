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
    | "### V\(.version) — \($heading)\n\n```sql\n" + (.statements | join("\n")) + "\n```"
  ] | join("\n\n")
' "$log_path"

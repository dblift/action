#!/bin/bash
# config/scripts inputs: empty omits the flag; non-empty reaches the command
# run, the pending-count probe, and the dry-run plan. args still skips the
# probe.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
run_script="$repo_root/scripts/run.sh"
tmp_root="$repo_root/tests/tmp/test-config-scripts"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

flags_stub="$tmp_root/dblift-flags-stub.sh"
cat > "$flags_stub" <<'STUB'
#!/bin/bash
{
  echo '---'
  printf '%s\n' "$@"
} >> "$RUNNER_TEMP/dblift-argv.log"
for arg in "$@"; do
  if [ "$arg" = "info" ]; then
    echo '{ "migrations": [] }'
    exit 0
  fi
done
exit 0
STUB
chmod +x "$flags_stub"

run_once() {
  local command="$1" args="$2"
  local runner="$tmp_root/runner-$$-$RANDOM"
  mkdir -p "$runner"
  LAST_OUTPUT="$tmp_root/out-$$-$RANDOM"
  LAST_STDERR="$tmp_root/err-$$-$RANDOM"
  LAST_RUNNER="$runner"
  : > "$LAST_OUTPUT"
  set +e
  env \
    INPUT_COMMAND="$command" \
    INPUT_ARGS="$args" \
    INPUT_WORKING_DIRECTORY="$tmp_root" \
    INPUT_ENV_NAME="${INPUT_ENV_NAME-}" \
    INPUT_CONFIG="${INPUT_CONFIG-}" \
    INPUT_SCRIPTS="${INPUT_SCRIPTS-}" \
    INPUT_SUMMARY="false" \
    GITHUB_OUTPUT="$LAST_OUTPUT" \
    GITHUB_STEP_SUMMARY="$tmp_root/summary" \
    RUNNER_TEMP="$runner" \
    DBLIFT_BIN="$flags_stub" \
    bash "$run_script" >/dev/null 2>"$LAST_STDERR"
  LAST_EXIT=$?
  set -e
}

run_once migrate ""
if grep -qxF -- '--config' "$LAST_RUNNER/dblift-argv.log"; then
  fail "empty config must omit --config"
fi
if grep -qxF -- '--scripts' "$LAST_RUNNER/dblift-argv.log"; then
  fail "empty scripts must omit --scripts"
fi

INPUT_CONFIG="dblift.ci.yaml" INPUT_SCRIPTS="db/migrations" run_once migrate ""
invocations=$(grep -c '^---$' "$LAST_RUNNER/dblift-argv.log" || true)
if [ "$invocations" -lt 2 ]; then
  fail "expected command run and pending-count probe, got $invocations"
fi
if [ "$(grep -cxF -- '--config' "$LAST_RUNNER/dblift-argv.log")" -lt 2 ]; then
  fail "expected --config on run and probe (argv: $(tr '\n' '|' < "$LAST_RUNNER/dblift-argv.log"))"
fi
if [ "$(grep -cxF -- '--scripts' "$LAST_RUNNER/dblift-argv.log")" -lt 2 ]; then
  fail "expected --scripts on run and probe"
fi
if ! grep -qxF -- 'dblift.ci.yaml' "$LAST_RUNNER/dblift-argv.log"; then
  fail "expected config path on argv"
fi
if ! grep -qxF -- 'db/migrations' "$LAST_RUNNER/dblift-argv.log"; then
  fail "expected scripts path on argv"
fi

INPUT_CONFIG="dblift.ci.yaml" INPUT_SCRIPTS="db/migrations" run_once "" "info"
pending=$(grep '^pending-count=' "$LAST_OUTPUT" | tail -n1 | cut -d= -f2-)
if [ "$pending" != "" ]; then
  fail "args mode must leave pending-count empty, got '$pending'"
fi
if ! grep -q "pending-count is not computed" "$LAST_STDERR"; then
  fail "args mode must log the skipped probe"
fi

# Plan step body: same flags, empty omits.
python3 - "$repo_root" "$tmp_root" <<'PY'
import sys, yaml
from pathlib import Path
repo, tmp = sys.argv[1], sys.argv[2]
action = yaml.safe_load(Path(repo, "action.yml").read_text())
plan = next(s for s in action["runs"]["steps"] if s.get("id") == "plan")
Path(tmp, "plan-body.sh").write_text(plan["run"])
PY

plan_stub="$tmp_root/plan-stub.sh"
cat > "$plan_stub" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$PLAN_ARGV_LOG"
log_dir="" log_file="" prev=""
for arg in "$@"; do
  case "$prev" in
    --log-dir) log_dir="$arg" ;;
    --log-file) log_file="$arg" ;;
  esac
  prev="$arg"
done
if [ -n "$log_dir" ] && [ -n "$log_file" ]; then
  mkdir -p "$log_dir"
  echo '{}' > "$log_dir/$log_file"
fi
exit 0
STUB
chmod +x "$plan_stub"

run_plan() {
  local argv_log="$1"
  shift
  mkdir -p "$tmp_root/work" "$tmp_root/plan-runner"
  set +e
  env \
    INPUT_WORKING_DIRECTORY="$tmp_root/work" \
    INPUT_ENV_NAME="" \
    INPUT_CONFIG="${1-}" \
    INPUT_SCRIPTS="${2-}" \
    RUNNER_TEMP="$tmp_root/plan-runner" \
    GITHUB_OUTPUT="$tmp_root/plan-out" \
    GITHUB_STEP_SUMMARY="$tmp_root/plan-sum" \
    GITHUB_ACTION_PATH="$repo_root" \
    DBLIFT_BIN="$plan_stub" \
    PLAN_ARGV_LOG="$argv_log" \
    bash "$tmp_root/plan-body.sh" >/dev/null 2>"$tmp_root/plan-err"
  set -e
}

run_plan "$tmp_root/plan-argv-empty.log" "" ""
for unexpected in --config --scripts; do
  if grep -qxF -- "$unexpected" "$tmp_root/plan-argv-empty.log"; then
    fail "plan: empty config/scripts must omit $unexpected"
  fi
done

run_plan "$tmp_root/plan-argv-set.log" "dblift.ci.yaml" "db/migrations"
for expected in --config dblift.ci.yaml --scripts db/migrations migrate --dry-run; do
  if ! grep -qxF -- "$expected" "$tmp_root/plan-argv-set.log"; then
    fail "plan: expected '$expected' (argv: $(tr '\n' ' ' < "$tmp_root/plan-argv-set.log"))"
  fi
done

if [ "$failures" -eq 0 ]; then
  echo "test-config-scripts.sh: all cases passed"
fi
exit "$failures"

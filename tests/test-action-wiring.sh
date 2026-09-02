#!/bin/bash
set -euo pipefail

# Test that action.yml's steps are wired correctly: scripts run under
# $GITHUB_ACTION_PATH, every run step declares shell: bash, the step ids the
# outputs reference exist, the install and dblift steps' env forward every
# INPUT_* variable their scripts read, the plan/comment step is gated on
# pr-comment, no step uses continue-on-error (not a documented composite-step
# key), and setup-python declares no cache (it throws when its dependency
# glob matches nothing).
repo_root=$(cd "$(dirname "$0")/.." && pwd)

tmp_root="$repo_root/tests/tmp/test-action-wiring"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

python3 << EOF
import re
import sys
import yaml

repo_root = "${repo_root}"
tmp_root = "${tmp_root}"

with open(f"{repo_root}/action.yml") as f:
    action = yaml.safe_load(f)

steps = action.get('runs', {}).get('steps', [])
if not steps:
    print("ERROR: runs.steps is empty", file=sys.stderr)
    sys.exit(1)

errors = []

run_steps = [s for s in steps if 'run' in s]
if not run_steps:
    errors.append("no step has a 'run' key")

for step in run_steps:
    if step.get('shell') != 'bash':
        errors.append(
            f"step '{step.get('name', step.get('id', '?'))}' has 'run' but shell is "
            f"'{step.get('shell')}', not 'bash'"
        )

script_ref_re = re.compile(r'[^\s"]*\.sh\b')
found_script_ref = False

for step in run_steps:
    for match in script_ref_re.findall(step['run']):
        found_script_ref = True
        if not match.startswith('$GITHUB_ACTION_PATH/'):
            errors.append(
                f"script reference '{match}' in step "
                f"'{step.get('name', step.get('id', '?'))}' is not rooted at "
                f"$GITHUB_ACTION_PATH"
            )

if not found_script_ref:
    errors.append("no .sh script reference found in any run step")

step_ids = {s['id'] for s in steps if 'id' in s}
outputs = action.get('outputs', {})
output_step_re = re.compile(r'steps\.([A-Za-z0-9_-]+)\.outputs\.')
referenced_ids = set()

for output_name, output in outputs.items():
    value = output.get('value', '')
    m = output_step_re.search(value)
    if not m:
        errors.append(f"output '{output_name}' value does not reference a step: '{value}'")
        continue
    referenced_ids.add(m.group(1))

for expected_id in ('dblift', 'plan'):
    if expected_id not in referenced_ids:
        errors.append(f"no output references step id '{expected_id}'")
    if expected_id not in step_ids:
        errors.append(f"step id '{expected_id}' referenced by an output does not exist in runs.steps")

expected_env_by_step = {
    'install': {
        'INPUT_PACKAGES',
        'INPUT_VERSION',
        'INPUT_EXTRAS',
        'INPUT_INDEX_URL',
    },
    'plan': {
        'INPUT_WORKING_DIRECTORY',
        'INPUT_ENV_NAME',
        'INPUT_CONFIG',
        'INPUT_SCRIPTS',
        'INPUT_SUMMARY',
    },
    'dblift': {
        'INPUT_COMMAND',
        'INPUT_ARGS',
        'INPUT_WORKING_DIRECTORY',
        'INPUT_ENV_NAME',
        'INPUT_CONFIG',
        'INPUT_SCRIPTS',
        'INPUT_SUMMARY',
    },
}

for step_id, expected_input_vars in expected_env_by_step.items():
    step = next((s for s in steps if s.get('id') == step_id), None)
    if step is None:
        errors.append(f"no step has id '{step_id}'")
        continue
    env = step.get('env', {}) or {}
    actual_input_vars = {k for k in env.keys() if k.startswith('INPUT_')}
    missing = expected_input_vars - actual_input_vars
    extra = actual_input_vars - expected_input_vars
    if missing:
        errors.append(f"{step_id} step env is missing: {', '.join(sorted(missing))}")
    if extra:
        errors.append(f"{step_id} step env has unexpected INPUT_* vars: {', '.join(sorted(extra))}")

for step in steps:
    if 'continue-on-error' in step:
        errors.append(
            f"step '{step.get('name', step.get('id', '?'))}' uses continue-on-error, "
            f"which is not a documented composite-step key"
        )

setup_python_steps = [
    s for s in steps
    if isinstance(s.get('uses'), str) and s['uses'].startswith('actions/setup-python@')
]
if not setup_python_steps:
    errors.append("no step uses actions/setup-python")
for step in setup_python_steps:
    with_block = step.get('with', {}) or {}
    if 'cache' in with_block:
        errors.append(
            f"setup-python step requests 'cache: {with_block['cache']}'; it throws on a "
            f"runner where its dependency glob matches nothing"
        )

comment_step = next(
    (s for s in run_steps if 'comment.sh' in s.get('run', '')),
    None,
)
if comment_step is None:
    errors.append("no run step invokes scripts/comment.sh")
else:
    condition = comment_step.get('if', '')
    normalized = ''.join(condition.split())
    if normalized != "inputs.pr-comment=='true'&&inputs.args==''":
        errors.append(
            f"comment step 'if' is '{condition}', expected it to gate on "
            f"inputs.pr-comment == 'true' && inputs.args == '' (with raw args "
            f"the dry run cannot replicate the real invocation)"
        )

def step_index(predicate, label):
    for i, step in enumerate(steps):
        if predicate(step):
            return i
    errors.append(f"no step matches {label}")
    return None

order = [
    ('actions/setup-python', step_index(
        lambda s: isinstance(s.get('uses'), str) and s['uses'].startswith('actions/setup-python@'),
        'actions/setup-python',
    )),
    ('install', step_index(lambda s: s.get('id') == 'install', "id 'install'")),
    ('plan', step_index(lambda s: s.get('id') == 'plan', "id 'plan'")),
    ('dblift', step_index(lambda s: s.get('id') == 'dblift', "id 'dblift'")),
]

if all(i is not None for _, i in order):
    for (prev_label, prev_i), (next_label, next_i) in zip(order, order[1:]):
        if prev_i > next_i:
            errors.append(
                f"step '{prev_label}' (position {prev_i}) must come before "
                f"'{next_label}' (position {next_i})"
            )

plan_step = next((s for s in steps if s.get('id') == 'plan'), None)
if plan_step is not None:
    with open(f"{tmp_root}/plan-body.sh", "w") as out:
        out.write(plan_step.get('run', ''))

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print("test-action-wiring.sh: static checks passed")
sys.exit(0)

EOF

plan_body="$tmp_root/plan-body.sh"
failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

if [ ! -s "$plan_body" ]; then
  echo "ERROR: the plan step body was not extracted to $plan_body" >&2
  exit 1
fi

dblift_stub="$tmp_root/dblift-stub.sh"
cat > "$dblift_stub" <<'STUB'
#!/bin/bash
set -euo pipefail
pwd -P > "$PLAN_CWD_LOG"
printf '%s\n' "$@" > "$PLAN_ARGV_LOG"
log_dir=""
log_file=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --log-dir) log_dir="$arg" ;;
    --log-file) log_file="$arg" ;;
  esac
  prev="$arg"
done
if [ -n "$log_dir" ] && [ -n "$log_file" ]; then
  printf '%s\n' "$log_dir/$log_file" > "$PLAN_LOG_PATH_LOG"
  cp "$PLAN_FIXTURE" "$log_dir/$log_file"
fi
STUB
chmod +x "$dblift_stub"

work_dir="$tmp_root/workdir"
mkdir -p "$work_dir"
runner_temp="$tmp_root/runner-temp"
mkdir -p "$runner_temp"
plan_output="$tmp_root/github-output"
plan_summary="$tmp_root/github-summary"
: > "$plan_output"
: > "$plan_summary"

set +e
env \
  INPUT_WORKING_DIRECTORY="$work_dir" \
  INPUT_ENV_NAME="" \
  RUNNER_TEMP="$runner_temp" \
  GITHUB_OUTPUT="$plan_output" \
  GITHUB_STEP_SUMMARY="$plan_summary" \
  GITHUB_ACTION_PATH="$repo_root" \
  DBLIFT_BIN="$dblift_stub" \
  PLAN_CWD_LOG="$tmp_root/cwd.log" \
  PLAN_ARGV_LOG="$tmp_root/argv.log" \
  PLAN_LOG_PATH_LOG="$tmp_root/logpath.log" \
  PLAN_FIXTURE="$repo_root/tests/fixtures/plan.json" \
  bash "$plan_body" > "$tmp_root/plan-stdout" 2> "$tmp_root/plan-stderr"
plan_exit=$?
set -e

if [ "$plan_exit" -ne 0 ]; then
  fail "plan body: expected exit 0, got $plan_exit (stderr: $(cat "$tmp_root/plan-stderr"))"
fi

for expected in migrate --dry-run --show-sql --log-format; do
  if ! grep -qxF -- "$expected" "$tmp_root/argv.log"; then
    fail "plan body: expected dblift to be invoked with '$expected' (argv: $(tr '\n' ' ' < "$tmp_root/argv.log"))"
  fi
done

actual_log_path=$(cat "$tmp_root/logpath.log" 2>/dev/null || true)
if [ "$actual_log_path" != "$runner_temp/plan.json" ]; then
  fail "plan body: expected the JSON log at '$runner_temp/plan.json', got '$actual_log_path'"
fi
if [ -e "$work_dir/plan.json" ] || [ -e "$work_dir/plan.md" ]; then
  fail "plan body: wrote plan artefacts into the working directory: $(ls -A "$work_dir")"
fi

if ! grep -q '^sql<<' "$plan_output"; then
  fail "plan body: expected a 'sql<<' heredoc in \$GITHUB_OUTPUT (output: $(cat "$plan_output"))"
fi
if ! grep -q '^### V' "$plan_output"; then
  fail "plan body: expected the rendered plan headings in the sql output (output: $(cat "$plan_output"))"
fi

expected_cwd=$(cd "$work_dir" && pwd -P)
actual_cwd=$(cat "$tmp_root/cwd.log" 2>/dev/null || true)
if [ "$actual_cwd" != "$expected_cwd" ]; then
  fail "plan body: expected dblift to run in '$expected_cwd', got '$actual_cwd'"
fi

failing_stub="$tmp_root/dblift-failing.sh"
cat > "$failing_stub" <<'STUB'
#!/bin/bash
echo "stub dblift: simulated failure" >&2
exit 4
STUB
chmod +x "$failing_stub"

set +e
env \
  INPUT_WORKING_DIRECTORY="$work_dir" \
  INPUT_ENV_NAME="" \
  RUNNER_TEMP="$runner_temp" \
  GITHUB_OUTPUT="$tmp_root/github-output-fail" \
  GITHUB_STEP_SUMMARY="$tmp_root/github-summary-fail" \
  GITHUB_ACTION_PATH="$repo_root" \
  DBLIFT_BIN="$failing_stub" \
  bash "$plan_body" > "$tmp_root/plan-stdout-fail" 2> "$tmp_root/plan-stderr-fail"
plan_fail_exit=$?
set -e

if [ "$plan_fail_exit" -ne 0 ]; then
  fail "plan body: a failing dblift must not fail the step, got exit $plan_fail_exit"
fi
if ! grep -qF 'could not render the migration plan' "$tmp_root/plan-stderr-fail"; then
  fail "plan body: expected the failure to be reported on stderr (stderr: $(cat "$tmp_root/plan-stderr-fail"))"
fi

if [ "$failures" -eq 0 ]; then
  echo "test-action-wiring.sh: all checks passed"
fi

exit "$failures"

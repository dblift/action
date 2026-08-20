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

# --- Every run step declares shell: bash ------------------------------------

run_steps = [s for s in steps if 'run' in s]
if not run_steps:
    errors.append("no step has a 'run' key")

for step in run_steps:
    if step.get('shell') != 'bash':
        errors.append(
            f"step '{step.get('name', step.get('id', '?'))}' has 'run' but shell is "
            f"'{step.get('shell')}', not 'bash'"
        )

# --- Every script reference is under \$GITHUB_ACTION_PATH --------------------

script_ref_re = re.compile(r'[^\s"]*\.sh\b')
found_script_ref = False

for step in run_steps:
    for match in script_ref_re.findall(step['run']):
        found_script_ref = True
        if not match.startswith('\$GITHUB_ACTION_PATH/'):
            errors.append(
                f"script reference '{match}' in step "
                f"'{step.get('name', step.get('id', '?'))}' is not rooted at "
                f"\$GITHUB_ACTION_PATH"
            )

if not found_script_ref:
    errors.append("no .sh script reference found in any run step")

# --- The step ids the outputs reference both exist ---------------------------

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

# --- The dblift step's env forwards every INPUT_* variable run.sh reads -----

# scripts/install.sh owns the install; scripts/run.sh no longer reads any of
# the install inputs. Each step must forward exactly the variables its script
# reads -- no more, no less.
expected_env_by_step = {
    'install': {
        'INPUT_PACKAGES',
        'INPUT_VERSION',
        'INPUT_EXTRAS',
        'INPUT_INDEX_URL',
    },
    'dblift': {
        'INPUT_COMMAND',
        'INPUT_ARGS',
        'INPUT_WORKING_DIRECTORY',
        'INPUT_ENV_NAME',
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

# --- No step uses continue-on-error -----------------------------------------
# continue-on-error is not part of the documented schema for a step inside a
# composite action's runs.steps: depending on the runner it is honoured,
# ignored, or rejected at manifest load. The plan step absorbs its own
# failures in its shell body instead, so no step may rely on this key.

for step in steps:
    if 'continue-on-error' in step:
        errors.append(
            f"step '{step.get('name', step.get('id', '?'))}' uses continue-on-error, "
            f"which is not a documented composite-step key"
        )

# --- setup-python must not request pip caching -------------------------------
# actions/setup-python with a 'cache: pip' request and no cache-dependency-path globs
# **/requirements.txt and THROWS when nothing matches. This repository tracks
# no pip dependency file, and neither do most calling migration repositories,
# so the Action would fail at its very first step on a fresh runner.

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

# --- The comment step is conditional on inputs.pr-comment == 'true' ---------

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

# --- Step order: setup-python, then install, then plan, then run ------------
# The plan must be rendered BEFORE the run step applies anything, or a
# dry-run preview of "migrate" reports an empty plan every time
# because those commands have already applied the migrations being previewed.
# Both of those in turn need dblift installed, so install comes first.

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

# --- Dump the plan step's shell body so the cases below can execute it ------

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

# --- Behavioural cases: execute the plan step's shell body ------------------
# The body above is inline shell inside action.yml, so nothing else in this
# suite can reach it. The python block dumped it to $tmp_root/plan-body.sh;
# these cases run it against a recording stub standing in for dblift (via the
# body's DBLIFT_BIN hook) and assert the guarantees that matter:
#   - the dry-run flags are present, so the plan step can never apply
#     migrations to the caller's database;
#   - the JSON log is written under $RUNNER_TEMP (Global Constraint 4);
#   - the rendered plan reaches the step's `sql` output;
#   - the body moves into INPUT_WORKING_DIRECTORY first.
# No network, no real dblift, no container.

plan_body="$tmp_root/plan-body.sh"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

if [ ! -s "$plan_body" ]; then
  echo "ERROR: the plan step body was not extracted to $plan_body" >&2
  exit 1
fi

# Records its working directory and argv, then writes a canned plan log to
# wherever it was told to put one, so plan-sql.sh downstream has real input.
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

# --- The dry-run flags are present ------------------------------------------
# Without --dry-run the plan step would APPLY the caller's pending migrations
# while claiming to preview them.

for expected in migrate --dry-run --show-sql --log-format; do
  if ! grep -qxF -- "$expected" "$tmp_root/argv.log"; then
    fail "plan body: expected dblift to be invoked with '$expected' (argv: $(tr '\n' ' ' < "$tmp_root/argv.log"))"
  fi
done

# --- The JSON log is written under \$RUNNER_TEMP, never the workspace -------

actual_log_path=$(cat "$tmp_root/logpath.log" 2>/dev/null || true)
if [ "$actual_log_path" != "$runner_temp/plan.json" ]; then
  fail "plan body: expected the JSON log at '$runner_temp/plan.json', got '$actual_log_path'"
fi
if [ -e "$work_dir/plan.json" ] || [ -e "$work_dir/plan.md" ]; then
  fail "plan body: wrote plan artefacts into the working directory: $(ls -A "$work_dir")"
fi

# --- The rendered plan reaches the step's sql output ------------------------

if ! grep -q '^sql<<' "$plan_output"; then
  fail "plan body: expected a 'sql<<' heredoc in \$GITHUB_OUTPUT (output: $(cat "$plan_output"))"
fi
if ! grep -q '^### V' "$plan_output"; then
  fail "plan body: expected the rendered plan headings in the sql output (output: $(cat "$plan_output"))"
fi

# --- The body moves into INPUT_WORKING_DIRECTORY first ----------------------
# Without the cd, dblift reads its configuration from the workflow's default
# directory whenever working-directory is set.

expected_cwd=$(cd "$work_dir" && pwd -P)
actual_cwd=$(cat "$tmp_root/cwd.log" 2>/dev/null || true)
if [ "$actual_cwd" != "$expected_cwd" ]; then
  fail "plan body: expected dblift to run in '$expected_cwd', got '$actual_cwd'"
fi

# --- A failure anywhere in the body must not fail the step ------------------
# I6: continue-on-error is gone, so the body itself has to absorb failures.

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

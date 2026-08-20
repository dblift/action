#!/bin/bash
set -euo pipefail

# Test that action.yml's steps are wired correctly: scripts run under
# $GITHUB_ACTION_PATH, every run step declares shell: bash, the step ids the
# outputs reference exist, the dblift step's env forwards every INPUT_*
# variable run.sh reads, and the plan/comment step is gated on pr-comment.
repo_root=$(cd "$(dirname "$0")/.." && pwd)

python3 << EOF
import re
import sys
import yaml

repo_root = "${repo_root}"

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

expected_input_vars = {
    'INPUT_COMMAND',
    'INPUT_ARGS',
    'INPUT_PACKAGES',
    'INPUT_VERSION',
    'INPUT_EXTRAS',
    'INPUT_WORKING_DIRECTORY',
    'INPUT_ENV_NAME',
    'INPUT_INDEX_URL',
    'INPUT_SUMMARY',
}

dblift_step = next((s for s in steps if s.get('id') == 'dblift'), None)
if dblift_step is None:
    errors.append("no step has id 'dblift'")
else:
    env = dblift_step.get('env', {}) or {}
    actual_input_vars = {k for k in env.keys() if k.startswith('INPUT_')}
    missing = expected_input_vars - actual_input_vars
    extra = actual_input_vars - expected_input_vars
    if missing:
        errors.append(f"dblift step env is missing: {', '.join(sorted(missing))}")
    if extra:
        errors.append(f"dblift step env has unexpected INPUT_* vars: {', '.join(sorted(extra))}")

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
    if normalized != "inputs.pr-comment=='true'":
        errors.append(
            f"comment step 'if' is '{condition}', expected it to gate on "
            f"inputs.pr-comment == 'true'"
        )

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print("test-action-wiring.sh: all checks passed")
sys.exit(0)

EOF

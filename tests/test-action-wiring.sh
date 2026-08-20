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

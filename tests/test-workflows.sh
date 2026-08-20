#!/bin/bash
set -euo pipefail

# Test .github/workflows and .github/dependabot.yml structure, that CI
# actually runs this repository's test suite against this checkout of the
# Action, and that the PostgreSQL recipe the README publishes is the one a
# job executes.
repo_root=$(cd "$(dirname "$0")/.." && pwd)

yaml_files=(
  "$repo_root/.github/workflows/test.yml"
  "$repo_root/.github/workflows/release.yml"
  "$repo_root/.github/dependabot.yml"
)

for f in "${yaml_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing $f" >&2
    exit 1
  fi
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" || {
    echo "ERROR: $f does not parse as valid YAML" >&2
    exit 1
  }
done

python3 << EOF
import yaml
import sys

repo_root = "${repo_root}"

# --- test.yml: both jobs present --------------------------------------------

with open(f"{repo_root}/.github/workflows/test.yml") as f:
    test_workflow = yaml.safe_load(f)

jobs = test_workflow.get('jobs', {})
if 'test' not in jobs:
    print("ERROR: test.yml is missing the 'test' job", file=sys.stderr)
    sys.exit(1)
if 'action-smoke-postgres' not in jobs:
    print("ERROR: test.yml is missing the 'action-smoke-postgres' job", file=sys.stderr)
    sys.exit(1)

# --- test.yml: pushes are only built on main ---------------------------------
# An unfiltered push trigger runs the whole suite twice for every commit
# pushed to an open pull request. (No backticks in this heredoc: it is
# unquoted, so the shell would run them as command substitutions.)

test_on = test_workflow.get(True) or test_workflow.get('on') or {}
push_trigger = test_on.get('push') or {}
if push_trigger.get('branches') != ['main']:
    print(
        f"ERROR: test.yml 'push' trigger is not filtered to ['main'] "
        f"(got: {push_trigger!r})",
        file=sys.stderr,
    )
    sys.exit(1)

postgres_job = jobs['action-smoke-postgres']
if not isinstance(postgres_job.get('services'), dict) or not postgres_job['services']:
    print("ERROR: test.yml 'action-smoke-postgres' job does not declare a 'services' block", file=sys.stderr)
    sys.exit(1)

# --- release.yml: triggers on release/published -----------------------------

with open(f"{repo_root}/.github/workflows/release.yml") as f:
    release_workflow = yaml.safe_load(f)

# PyYAML parses the bare 'on:' key as the boolean True, not the string "on".
on_section = release_workflow.get(True)
if on_section is None:
    on_section = release_workflow.get('on')
if not isinstance(on_section, dict):
    print(f"ERROR: release.yml has no 'on' trigger section (got: {on_section!r})", file=sys.stderr)
    sys.exit(1)

release_trigger = on_section.get('release')
if not isinstance(release_trigger, dict):
    print(f"ERROR: release.yml does not trigger on 'release' (got: {release_trigger!r})", file=sys.stderr)
    sys.exit(1)

types = release_trigger.get('types', [])
if 'published' not in types:
    print(f"ERROR: release.yml release trigger does not include type 'published' (got: {types})", file=sys.stderr)
    sys.exit(1)

# --- release.yml: contents: write is scoped to the retag job -----------------
# Only the retag job pushes a tag. Granting the write at workflow scope would
# hand the same token to the test job, which installs from PyPI and runs
# repository test code and needs no write access at all.

workflow_permissions = release_workflow.get('permissions', {}) or {}
if workflow_permissions.get('contents') == 'write':
    print(
        "ERROR: release.yml grants 'contents: write' at workflow scope; scope it "
        "to the retag job instead",
        file=sys.stderr,
    )
    sys.exit(1)

# --- release.yml: the retag job is gated on the test job passing -----------

release_jobs = release_workflow.get('jobs', {})
if 'test' not in release_jobs:
    print("ERROR: release.yml is missing the 'test' job", file=sys.stderr)
    sys.exit(1)
if 'retag' not in release_jobs:
    print("ERROR: release.yml is missing the 'retag' job", file=sys.stderr)
    sys.exit(1)

retag_permissions = release_jobs['retag'].get('permissions', {}) or {}
if retag_permissions.get('contents') != 'write':
    print(
        f"ERROR: release.yml 'retag' job does not declare 'contents: write' "
        f"(got: {retag_permissions})",
        file=sys.stderr,
    )
    sys.exit(1)

test_job_permissions = release_jobs['test'].get('permissions', {}) or {}
if test_job_permissions.get('contents') == 'write':
    print(
        "ERROR: release.yml 'test' job holds 'contents: write', which it never uses",
        file=sys.stderr,
    )
    sys.exit(1)

# --- test.yml: read-only token ----------------------------------------------

test_workflow_permissions = test_workflow.get('permissions', {}) or {}
if test_workflow_permissions.get('contents') != 'read':
    print(
        f"ERROR: test.yml does not declare 'contents: read' permissions "
        f"(got: {test_workflow_permissions})",
        file=sys.stderr,
    )
    sys.exit(1)

needs = release_jobs['retag'].get('needs')
needs_list = [needs] if isinstance(needs, str) else (needs or [])
if 'test' not in needs_list:
    print(f"ERROR: release.yml 'retag' job does not declare 'needs: test' (got: {needs!r})", file=sys.stderr)
    sys.exit(1)

# --- release.yml: prereleases skip instead of failing ------------------------
# The release/published trigger also fires for prereleases; without the guard
# a v4.0.0-rc1 publish hits the strict version check and turns the run red.

for job_name in ('test', 'retag'):
    condition = release_jobs[job_name].get('if', '') or ''
    if 'prerelease' not in condition:
        print(
            f"ERROR: release.yml '{job_name}' job is not guarded against "
            f"prerelease events (if: {condition!r})",
            file=sys.stderr,
        )
        sys.exit(1)

# --- CI must actually run the test suite ------------------------------------
# Replacing the suite invocation with anything else (a stub, an echo, a
# renamed script) leaves every other assertion here green while CI checks
# nothing at all.

suite_command = "bash tests/run.sh"

for workflow_name, workflow in (
    ("test.yml", test_workflow),
    ("release.yml", release_workflow),
):
    workflow_jobs = workflow.get("jobs", {})
    test_job = workflow_jobs.get("test")
    if test_job is None:
        print(f"ERROR: {workflow_name} is missing the 'test' job", file=sys.stderr)
        sys.exit(1)
    runs = [
        step.get("run", "").strip()
        for step in test_job.get("steps", [])
        if "run" in step
    ]
    if suite_command not in runs:
        print(
            f"ERROR: {workflow_name} 'test' job never runs '{suite_command}' "
            f"(run steps: {runs})",
            file=sys.stderr,
        )
        sys.exit(1)

# --- The smoke jobs must exercise THIS checkout of the Action ---------------
# Repointing them at a published tag would test whatever is already released
# rather than the change under review, and would still pass.

smoke_jobs = {
    name: job for name, job in jobs.items() if name.startswith("action-smoke")
}
if not smoke_jobs:
    print("ERROR: test.yml declares no action-smoke* job", file=sys.stderr)
    sys.exit(1)

for name, job in smoke_jobs.items():
    uses_values = [step.get("uses") for step in job.get("steps", []) if "uses" in step]
    if "./" not in uses_values:
        print(
            f"ERROR: test.yml '{name}' job does not run the Action from this "
            f"checkout with 'uses: ./' (uses values: {uses_values})",
            file=sys.stderr,
        )
        sys.exit(1)

# --- Every smoke job must assert on an output -------------------------------
# A smoke job that runs the Action but checks nothing passes whenever the
# Action merely exits 0, which is exactly the failure the pr-comment bug had.

required_output_assertions = [
    ("action-smoke-postgres", "pending-count"),
    ("action-smoke-plan", "sql"),
    ("action-smoke-plan", "pending-count"),
]

for name, output_name in required_output_assertions:
    job = jobs.get(name)
    if job is None:
        print(f"ERROR: test.yml is missing the '{name}' job", file=sys.stderr)
        sys.exit(1)
    reference = f"steps.dblift.outputs.{output_name}"
    asserting_steps = [
        step
        for step in job.get("steps", [])
        if "run" in step
        and any(reference in str(v) for v in (step.get("env", {}) or {}).values())
    ]
    if not asserting_steps:
        print(
            f"ERROR: test.yml '{name}' job has no step asserting on "
            f"{reference}",
            file=sys.stderr,
        )
        sys.exit(1)
    if not any("exit 1" in step["run"] for step in asserting_steps):
        print(
            f"ERROR: test.yml '{name}' job reads {reference} but never fails "
            f"the job on a bad value",
            file=sys.stderr,
        )
        sys.exit(1)

# --- action-smoke-plan must run a command that APPLIES ----------------------
# The job's whole value is proving the plan is rendered before the run step.
# That only holds if the command applies the migrations: with a
# non-destructive command the plan is non-empty under either ordering, and
# the job passes with the ordering bug present.

plan_job_step = next(
    (
        step
        for step in jobs['action-smoke-plan'].get('steps', [])
        if step.get('uses') == './'
    ),
    None,
)
if plan_job_step is None:
    print("ERROR: test.yml 'action-smoke-plan' job never invokes the Action", file=sys.stderr)
    sys.exit(1)

plan_job_with = plan_job_step.get('with', {}) or {}
if plan_job_with.get('command') != 'migrate':
    print(
        f"ERROR: test.yml 'action-smoke-plan' runs command "
        f"{plan_job_with.get('command')!r}; it must run 'migrate', or it passes "
        f"whether or not the plan is rendered before the run step",
        file=sys.stderr,
    )
    sys.exit(1)
if str(plan_job_with.get('pr-comment')).lower() != 'true':
    print(
        "ERROR: test.yml 'action-smoke-plan' does not enable pr-comment, so no "
        "plan is rendered at all",
        file=sys.stderr,
    )
    sys.exit(1)

# --- The published PostgreSQL recipe is the recipe a job executes -----------
# The README quick start is the copy-paste users start from. If it drifts from
# the job that proves it works -- a different image, a dropped health check --
# we would be publishing an untested recipe.

fence = chr(96) * 3

with open(f"{repo_root}/README.md") as f:
    readme = f.read()

open_marker = fence + "yaml"
open_at = readme.find(open_marker)
if open_at == -1:
    print("ERROR: README.md has no yaml code block", file=sys.stderr)
    sys.exit(1)
block_start = open_at + len(open_marker)
close_at = readme.find(fence, block_start)
if close_at == -1:
    print("ERROR: README.md's first yaml code block is never closed", file=sys.stderr)
    sys.exit(1)

readme_workflow = yaml.safe_load(readme[block_start:close_at])
readme_jobs = readme_workflow.get("jobs", {}) or {}
if len(readme_jobs) != 1:
    print(
        f"ERROR: README.md's first yaml block should define exactly one job, "
        f"found {sorted(readme_jobs)}",
        file=sys.stderr,
    )
    sys.exit(1)

readme_job = next(iter(readme_jobs.values()))
executed_job = jobs["action-smoke-postgres"]

for key in ("env", "services"):
    documented = readme_job.get(key)
    executed = executed_job.get(key)
    if not documented:
        print(
            f"ERROR: README.md's quick start declares no '{key}' block, so the "
            f"published recipe is not the one action-smoke-postgres executes",
            file=sys.stderr,
        )
        sys.exit(1)
    if documented != executed:
        print(
            f"ERROR: README.md's quick start '{key}' block differs from the "
            f"action-smoke-postgres job that executes it.\n"
            f"  README:  {documented!r}\n"
            f"  test.yml: {executed!r}",
            file=sys.stderr,
        )
        sys.exit(1)

print("workflow validation passed")
sys.exit(0)

EOF

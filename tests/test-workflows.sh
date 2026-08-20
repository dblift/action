#!/bin/bash
set -euo pipefail

# Test .github/workflows and .github/dependabot.yml structure.
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
if 'action-smoke' not in jobs:
    print("ERROR: test.yml is missing the 'action-smoke' job", file=sys.stderr)
    sys.exit(1)
if 'action-smoke-postgres' not in jobs:
    print("ERROR: test.yml is missing the 'action-smoke-postgres' job", file=sys.stderr)
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

# --- release.yml: declares contents: write -----------------------------------

permissions = release_workflow.get('permissions', {})
if permissions.get('contents') != 'write':
    print(f"ERROR: release.yml does not declare 'contents: write' permission (got: {permissions})", file=sys.stderr)
    sys.exit(1)

# --- release.yml: the retag job is gated on the test job passing -----------

release_jobs = release_workflow.get('jobs', {})
if 'test' not in release_jobs:
    print("ERROR: release.yml is missing the 'test' job", file=sys.stderr)
    sys.exit(1)
if 'retag' not in release_jobs:
    print("ERROR: release.yml is missing the 'retag' job", file=sys.stderr)
    sys.exit(1)

needs = release_jobs['retag'].get('needs')
needs_list = [needs] if isinstance(needs, str) else (needs or [])
if 'test' not in needs_list:
    print(f"ERROR: release.yml 'retag' job does not declare 'needs: test' (got: {needs!r})", file=sys.stderr)
    sys.exit(1)

print("workflow validation passed")
sys.exit(0)

EOF

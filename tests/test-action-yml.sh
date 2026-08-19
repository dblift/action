#!/bin/bash
set -euo pipefail

# Test action.yml structure and defaults
repo_root=$(cd "$(dirname "$0")/.." && pwd)

# First, verify YAML parses
python3 -c "import yaml,sys; yaml.safe_load(open('${repo_root}/action.yml'))" || {
  echo "ERROR: action.yml does not parse as valid YAML" >&2
  exit 1
}

# Now validate the structure with Python
python3 << EOF
import yaml
import sys

repo_root = "${repo_root}"

with open(f"{repo_root}/action.yml") as f:
    action = yaml.safe_load(f)

# Expected inputs with their defaults
expected_inputs = {
    'command': 'check',
    'args': '',
    'packages': '',
    'version': '',
    'extras': 'postgresql',
    'python-version': '3.11',
    'working-directory': '.',
    'env-name': '',
    'index-url': '',
    'summary': 'true',
    'pr-comment': 'false',
}

# Expected outputs
expected_outputs = {
    'exit-code',
    'pending-count',
    'sql',
}

# Verify metadata
if action.get('name') != 'DBLift':
    print("ERROR: name is not 'DBLift'", file=sys.stderr)
    sys.exit(1)

if action.get('author') != 'DBLift':
    print("ERROR: author is not 'DBLift'", file=sys.stderr)
    sys.exit(1)

if action.get('branding', {}).get('icon') != 'database':
    print("ERROR: branding icon is not 'database'", file=sys.stderr)
    sys.exit(1)

if action.get('branding', {}).get('color') != 'blue':
    print("ERROR: branding color is not 'blue'", file=sys.stderr)
    sys.exit(1)

if action.get('runs', {}).get('using') != 'composite':
    print("ERROR: runs.using is not 'composite'", file=sys.stderr)
    sys.exit(1)

# Verify all inputs present and have correct defaults
inputs = action.get('inputs', {})
for input_name, expected_default in expected_inputs.items():
    if input_name not in inputs:
        print(f"ERROR: input '{input_name}' is missing", file=sys.stderr)
        sys.exit(1)

    actual_default = inputs[input_name].get('default')
    if actual_default != expected_default:
        print(
            f"ERROR: input '{input_name}' has default '{actual_default}' but expected '{expected_default}'",
            file=sys.stderr
        )
        sys.exit(1)

# Verify no extra inputs
actual_input_names = set(inputs.keys())
if actual_input_names != set(expected_inputs.keys()):
    extra = actual_input_names - set(expected_inputs.keys())
    if extra:
        print(f"ERROR: unexpected inputs: {', '.join(extra)}", file=sys.stderr)
        sys.exit(1)

# Verify all outputs present
outputs = action.get('outputs', {})
actual_output_names = set(outputs.keys())
if actual_output_names != expected_outputs:
    missing = expected_outputs - actual_output_names
    extra = actual_output_names - expected_outputs
    if missing:
        print(f"ERROR: missing outputs: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    if extra:
        print(f"ERROR: unexpected outputs: {', '.join(extra)}", file=sys.stderr)
        sys.exit(1)

# Verify output values reference the correct step
for output_name in expected_outputs:
    output = outputs[output_name]
    value = output.get('value', '')
    if 'steps.dblift.outputs' not in value:
        print(
            f"ERROR: output '{output_name}' value does not reference steps.dblift.outputs",
            file=sys.stderr
        )
        sys.exit(1)

print("action.yml validation passed")
sys.exit(0)

EOF

# Verify LICENSE is Apache 2.0 text
if ! grep -q "Licensed under the Apache License, Version 2.0" "${repo_root}/LICENSE"; then
  echo "ERROR: LICENSE does not contain Apache 2.0 text" >&2
  exit 1
fi

if ! grep -q "Copyright 2024 DBLift" "${repo_root}/LICENSE"; then
  echo "ERROR: LICENSE does not have correct copyright holder" >&2
  exit 1
fi

exit 0

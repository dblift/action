#!/bin/bash
# Install dblift, run the requested command, and report the result.
#
# Reads INPUT_COMMAND, INPUT_ARGS, INPUT_PACKAGES, INPUT_VERSION, INPUT_EXTRAS,
# INPUT_WORKING_DIRECTORY, INPUT_ENV_NAME, INPUT_INDEX_URL, INPUT_SUMMARY from
# the environment (as set by the composite action from its inputs), plus the
# runner-provided GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and RUNNER_TEMP.
#
# Test-only hooks, not used in production:
#   DBLIFT_BIN          - dblift executable to invoke (default: dblift)
#   DBLIFT_SKIP_INSTALL - when "1", skip the pip install step
set -euo pipefail

dblift_bin="${DBLIFT_BIN:-dblift}"

# --- 1. Resolve the install specifier and install it ------------------------

install_specifiers=()
read -ra install_specifiers <<< "${INPUT_PACKAGES:-}"

if [ "${#install_specifiers[@]}" -eq 0 ]; then
  install_target="dblift[${INPUT_EXTRAS:-}]"
  if [ -n "${INPUT_VERSION:-}" ]; then
    install_target="${install_target}==${INPUT_VERSION}"
  fi
  read -ra install_specifiers <<< "$install_target"
fi

echo "Installing: ${install_specifiers[*]}"

if [ "${DBLIFT_SKIP_INSTALL:-}" != "1" ]; then
  install_cmd=(install)
  if [ -n "${INPUT_INDEX_URL:-}" ]; then
    install_cmd+=(--index-url "$INPUT_INDEX_URL")
  fi
  install_cmd+=("${install_specifiers[@]}")

  pip "${install_cmd[@]}"
fi

# --- 2. Move into the working directory --------------------------------------

cd "${INPUT_WORKING_DIRECTORY:-}"

# --- 3/4. Build and run the command, streaming and capturing its output -----

capture_file="$RUNNER_TEMP/dblift-run-output.log"
: > "$capture_file"

exit_code=0
ran_commands=""

run_dblift() {
  local cmd=("$dblift_bin" "$@")
  if [ -n "${INPUT_ENV_NAME:-}" ]; then
    cmd+=(--env "$INPUT_ENV_NAME")
  fi

  if [ -n "$ran_commands" ]; then
    ran_commands="${ran_commands}
${cmd[*]}"
  else
    ran_commands="${cmd[*]}"
  fi

  set +e
  "${cmd[@]}" 2>&1 | tee -a "$capture_file"
  exit_code="${PIPESTATUS[0]}"
  set -e
}

extra_args=()
read -ra extra_args <<< "${INPUT_ARGS:-}"

if [ "${#extra_args[@]}" -gt 0 ]; then
  run_dblift "${extra_args[@]}"
else
  case "${INPUT_COMMAND:-}" in
    migrate)
      run_dblift migrate
      ;;
    validate)
      run_dblift validate
      ;;
    info)
      run_dblift info
      ;;
    check)
      run_dblift migrate
      if [ "$exit_code" -eq 0 ]; then
        run_dblift validate
      fi
      if [ "$exit_code" -eq 0 ]; then
        run_dblift info
      fi
      ;;
    *)
      echo "run.sh: unknown command '${INPUT_COMMAND:-}' (valid values: migrate, validate, info, check)" >&2
      exit 2
      ;;
  esac
fi

# --- 5. Compute pending-count, independently of the run above ---------------

pending_count=""

probe_cmd=("$dblift_bin" info --format json)
if [ -n "${INPUT_ENV_NAME:-}" ]; then
  probe_cmd+=(--env "$INPUT_ENV_NAME")
fi

if info_json=$("${probe_cmd[@]}"); then
  if parsed=$(printf '%s' "$info_json" | jq '[.migrations[] | select(.status == "PENDING")] | length' 2>/dev/null); then
    pending_count="$parsed"
  fi
fi

# --- 6. Write outputs ---------------------------------------------------------

{
  echo "exit-code=${exit_code}"
  echo "pending-count=${pending_count}"
} >> "$GITHUB_OUTPUT"

# --- 7. Write the step summary -----------------------------------------------

if [ "${INPUT_SUMMARY:-}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### dblift"
    echo
    echo "**Command:**"
    echo '```'
    echo "$ran_commands"
    echo '```'
    echo
    echo "**Exit status:** ${exit_code}"
    echo
    echo "**Pending migrations:** ${pending_count}"
    echo
    echo "**Output:**"
    echo '```'
    cat "$capture_file"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# --- 8. Exit with the dblift exit status -------------------------------------

exit "$exit_code"

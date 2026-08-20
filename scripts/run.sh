#!/bin/bash
# Run the requested dblift command and report the result.
#
# dblift is installed by scripts/install.sh in an earlier composite step; this
# script consumes an already-installed dblift and never installs anything.
#
# Reads INPUT_COMMAND, INPUT_ARGS, INPUT_WORKING_DIRECTORY, INPUT_ENV_NAME and
# INPUT_SUMMARY from the environment (as set by the composite action from its
# inputs), plus the runner-provided GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and
# RUNNER_TEMP.
#
# Test-only hook, not used in production:
#   DBLIFT_BIN - dblift executable to invoke (default: dblift)
set -euo pipefail

dblift_bin="${DBLIFT_BIN:-dblift}"

# --- 1. Move into the working directory --------------------------------------

cd "${INPUT_WORKING_DIRECTORY:-}"

# --- 2/3. Build and run the command, streaming and capturing its output -----

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

# --- 4. Compute pending-count, independently of the run above ---------------

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

# --- 5. Write outputs ---------------------------------------------------------

{
  echo "exit-code=${exit_code}"
  echo "pending-count=${pending_count}"
} >> "$GITHUB_OUTPUT"

# --- 6. Write the step summary -----------------------------------------------

# Reads content on stdin and prints the Markdown fence to wrap it in: one
# backtick longer than the longest run of backticks the content holds, and
# never shorter than three. Per CommonMark a fenced block is only closed by a
# run of backticks at least as long as the one that opened it, so a fixed
# three-backtick fence is broken out of by any content that contains a fence
# of its own -- and both blocks below wrap content this script does not
# control (raw dblift output, and the caller's own `args`).
fence_for() {
  local longest len

  longest=$(awk '
    {
      run = 0
      for (i = 1; i <= length($0); i++) {
        if (substr($0, i, 1) == "`") {
          run++
          if (run > max) max = run
        } else {
          run = 0
        }
      }
    }
    END { print max + 0 }
  ')

  len=3
  if [ "$((longest + 1))" -gt "$len" ]; then
    len=$((longest + 1))
  fi

  printf '%*s' "$len" '' | tr ' ' '`'
}

if [ "${INPUT_SUMMARY:-}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  command_fence=$(printf '%s\n' "$ran_commands" | fence_for)
  output_fence=$(fence_for < "$capture_file")

  {
    echo "### dblift"
    echo
    echo "**Command:**"
    echo "$command_fence"
    echo "$ran_commands"
    echo "$command_fence"
    echo
    echo "**Exit status:** ${exit_code}"
    echo
    echo "**Pending migrations:** ${pending_count}"
    echo
    echo "**Output:**"
    echo "$output_fence"
    cat "$capture_file"
    echo "$output_fence"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# --- 7. Exit with the dblift exit status -------------------------------------

exit "$exit_code"

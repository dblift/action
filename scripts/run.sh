#!/bin/bash
# Run the requested dblift command and report the result.
#
# INPUT_ARGS, when non-empty, is split like a shell command line (quotes
# supported) and passed to dblift; INPUT_COMMAND is then ignored. Otherwise
# INPUT_COMMAND must name one of migrate, validate or info.
# There is no default and no composite pipeline: with neither set, this script
# exits 2 rather than guessing at a command that might apply migrations.
#
# dblift is installed by scripts/install.sh in an earlier composite step; this
# script consumes an already-installed dblift and never installs anything.
#
# Reads INPUT_COMMAND, INPUT_ARGS, INPUT_WORKING_DIRECTORY, INPUT_ENV_NAME,
# INPUT_CONFIG, INPUT_SCRIPTS and INPUT_SUMMARY from the environment (as set
# by the composite action from its inputs), plus the runner-provided
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and RUNNER_TEMP.
#
# Test-only hook, not used in production:
#   DBLIFT_BIN - dblift executable to invoke (default: dblift)
set -euo pipefail

dblift_bin="${DBLIFT_BIN:-dblift}"

# The exit-code and pending-count outputs are part of the Action's contract on
# every path, including the early failures below (bad working-directory, no
# command). Without this trap, `continue-on-error: true` consumers would read
# an empty string instead of a status exactly on the paths where they need it.
outputs_written=0
write_outputs_on_exit() {
  local status=$?
  if [ "$outputs_written" -eq 0 ]; then
    {
      echo "exit-code=${status}"
      echo "pending-count="
    } >> "$GITHUB_OUTPUT"
  fi
}
trap write_outputs_on_exit EXIT

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
  if [ -n "${INPUT_CONFIG:-}" ]; then
    cmd+=(--config "$INPUT_CONFIG")
  fi
  if [ -n "${INPUT_SCRIPTS:-}" ]; then
    cmd+=(--scripts "$INPUT_SCRIPTS")
  fi

  if [ -n "$ran_commands" ]; then
    ran_commands="${ran_commands}
${cmd[*]}"
  else
    ran_commands="${cmd[*]}"
  fi

  # --log-dir routes dblift's own log file into the runner temp directory.
  # The CLI defaults to a relative ./logs, which would leave a stray
  # directory inside the caller's checkout on every run. It is inserted at
  # invocation time so the step summary shows the command the user asked for.
  set +e
  "${cmd[0]}" --log-dir "$RUNNER_TEMP/dblift-logs" "${cmd[@]:1}" 2>&1 | tee -a "$capture_file"
  exit_code="${PIPESTATUS[0]}"
  set -e
}

# Shell-style tokenization: quoted arguments (e.g. --description "add users
# table") and multi-line values survive intact, and an unbalanced quote fails
# loudly instead of silently corrupting the command line. python3 is guaranteed
# by the setup-python step that precedes this script.
extra_args=()
if [ -n "${INPUT_ARGS:-}" ]; then
  if ! parsed_args=$(printf '%s' "$INPUT_ARGS" | python3 -c '
import shlex, sys
print("\n".join(shlex.split(sys.stdin.read())))
'); then
    echo "run.sh: could not parse 'args' (unbalanced quote?): ${INPUT_ARGS}" >&2
    exit 2
  fi
  if [ -n "$parsed_args" ]; then
    while IFS= read -r arg_token; do
      extra_args+=("$arg_token")
    done <<< "$parsed_args"
  fi
fi

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
    "")
      echo "run.sh: no command given (valid values: migrate, validate, info); alternatively set 'args' to pass raw arguments to the dblift CLI" >&2
      exit 2
      ;;
    *)
      echo "run.sh: unknown command '${INPUT_COMMAND:-}' (valid values: migrate, validate, info)" >&2
      exit 2
      ;;
  esac
fi

# --- 4. Compute pending-count, independently of the run above ---------------
# The probe rebuilds its own `dblift info` command from the working directory
# plus --env, --config and --scripts, so it is only run when the command came
# from INPUT_COMMAND: with raw `args` the probe cannot replicate arbitrary
# flags and would silently count against the wrong project. In that case
# pending-count stays empty, which the docs state. Probe failures are reported
# to stderr rather than swallowed -- an empty pending-count must be
# diagnosable from the log.

pending_count=""

if [ "${#extra_args[@]}" -gt 0 ]; then
  echo "run.sh: pending-count is not computed when 'args' is set (the probe cannot replicate raw arguments)" >&2
else
  probe_cmd=("$dblift_bin" --log-dir "$RUNNER_TEMP/dblift-logs" info --format json)
  if [ -n "${INPUT_ENV_NAME:-}" ]; then
    probe_cmd+=(--env "$INPUT_ENV_NAME")
  fi
  if [ -n "${INPUT_CONFIG:-}" ]; then
    probe_cmd+=(--config "$INPUT_CONFIG")
  fi
  if [ -n "${INPUT_SCRIPTS:-}" ]; then
    probe_cmd+=(--scripts "$INPUT_SCRIPTS")
  fi

  if ! info_json=$("${probe_cmd[@]}"); then
    echo "run.sh: pending-count probe failed: 'dblift info --format json' exited non-zero" >&2
  elif ! parsed=$(printf '%s' "$info_json" | jq '[.migrations[] | select(.status == "PENDING")] | length' 2>&1); then
    echo "run.sh: pending-count probe failed: could not parse 'dblift info' output as JSON: $parsed" >&2
  else
    pending_count="$parsed"
  fi
fi

# --- 5. Write outputs ---------------------------------------------------------

{
  echo "exit-code=${exit_code}"
  echo "pending-count=${pending_count}"
} >> "$GITHUB_OUTPUT"
outputs_written=1

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

#!/bin/bash
# Resolve the pip requirement specifier for dblift and install it.
#
# Reads INPUT_PACKAGES, INPUT_VERSION, INPUT_EXTRAS and INPUT_INDEX_URL from
# the environment (as set by the composite action from its inputs).
#
# Resolution precedence:
#   1. INPUT_PACKAGES, verbatim and whitespace-split, when it holds at least
#      one word.
#   2. Otherwise `dblift[<INPUT_EXTRAS>]`, with `==<INPUT_VERSION>` appended
#      when INPUT_VERSION is set.
# INPUT_INDEX_URL, when set, is passed to pip as --index-url either way.
#
# This runs as its own composite step, before the plan and run steps, so that
# both of them consume an already-installed dblift.
#
# Test-only hook, not used in production:
#   PIP_BIN - pip executable to invoke (default: pip)
set -euo pipefail

pip_bin="${PIP_BIN:-pip}"

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

install_cmd=(install)
if [ -n "${INPUT_INDEX_URL:-}" ]; then
  install_cmd+=(--index-url "$INPUT_INDEX_URL")
fi
install_cmd+=("${install_specifiers[@]}")

"$pip_bin" "${install_cmd[@]}"

#!/bin/bash
# Resolve the pip requirement specifier for dblift and install it.
#
# Reads INPUT_PACKAGES, INPUT_VERSION, INPUT_EXTRAS and INPUT_INDEX_URL from
# the environment (as set by the composite action from its inputs).
#
# Resolution precedence:
#   1. INPUT_PACKAGES, whitespace-split (newlines included), when it holds at
#      least one word.
#   2. Otherwise `dblift[<INPUT_EXTRAS>]`, with `==<INPUT_VERSION>` appended
#      when INPUT_VERSION is set; whitespace inside either value is stripped.
# INPUT_INDEX_URL, when set, is passed to pip as --index-url either way.
#
# This runs as its own composite step, before the plan and run steps, so that
# both of them consume an already-installed dblift.
#
# Test-only hook, not used in production:
#   PIP_BIN - pip executable to invoke (default: pip)
set -euo pipefail

pip_bin="${PIP_BIN:-pip}"

# Newlines become spaces first: `read -ra` stops at the first newline, which
# would silently drop every package after line 1 of a `packages: |` block.
packages_input="${INPUT_PACKAGES:-}"
packages_input="${packages_input//$'\n'/ }"

install_specifiers=()
read -ra install_specifiers <<< "$packages_input"

if [ "${#install_specifiers[@]}" -eq 0 ]; then
  # Strip whitespace so a natural `extras: 'postgresql, mysql'` builds the
  # valid specifier dblift[postgresql,mysql] instead of fracturing into two
  # bogus pip arguments.
  extras="${INPUT_EXTRAS:-}"
  extras="${extras//[[:space:]]/}"
  version="${INPUT_VERSION:-}"
  version="${version//[[:space:]]/}"

  install_target="dblift[${extras}]"
  if [ -n "$version" ]; then
    install_target="${install_target}==${version}"
  fi
  install_specifiers=("$install_target")
fi

echo "Installing: ${install_specifiers[*]}"

install_cmd=(install)
if [ -n "${INPUT_INDEX_URL:-}" ]; then
  install_cmd+=(--index-url "$INPUT_INDEX_URL")
fi
install_cmd+=("${install_specifiers[@]}")

"$pip_bin" "${install_cmd[@]}"

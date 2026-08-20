#!/bin/bash
# Verify scripts/install.sh resolves the pip requirement specifier correctly
# and hands it to pip. A recording stub stands in for pip via install.sh's
# PIP_BIN hook, so no case reaches the network.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
install_script="$repo_root/scripts/install.sh"

tmp_root="$repo_root/tests/tmp/test-install"
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# Records the argv it was called with, one space-joined line, so cases can
# assert on exactly what install.sh asked pip to do.
pip_stub="$tmp_root/pip-stub.sh"
cat > "$pip_stub" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PIP_LOG"
STUB
chmod +x "$pip_stub"

run_counter=0

# Runs scripts/install.sh with the given packages / version / extras /
# index-url. Sets LAST_EXIT, LAST_STDOUT_FILE, LAST_STDERR_FILE and
# LAST_PIP_LOG for the caller to assert on.
run_case() {
  local packages="$1" version="$2" extras="$3" index_url="${4:-}"
  run_counter=$((run_counter + 1))

  LAST_PIP_LOG="$tmp_root/pip-log-$run_counter"
  LAST_STDOUT_FILE="$tmp_root/stdout-$run_counter"
  LAST_STDERR_FILE="$tmp_root/stderr-$run_counter"
  : > "$LAST_PIP_LOG"

  set +e
  env \
    INPUT_PACKAGES="$packages" \
    INPUT_VERSION="$version" \
    INPUT_EXTRAS="$extras" \
    INPUT_INDEX_URL="$index_url" \
    PIP_BIN="$pip_stub" \
    PIP_LOG="$LAST_PIP_LOG" \
    bash "$install_script" >"$LAST_STDOUT_FILE" 2>"$LAST_STDERR_FILE"
  LAST_EXIT=$?
  set -e
}

assert_pip_argv() {
  local label="$1" expected="$2"
  local actual
  actual=$(cat "$LAST_PIP_LOG")
  if [ "$actual" != "$expected" ]; then
    fail "$label: expected pip argv '$expected', got '$actual'"
  fi
}

assert_installing_line() {
  local label="$1" expected="$2"
  if ! grep -qxF -- "Installing: $expected" "$LAST_STDOUT_FILE"; then
    fail "$label: expected the line 'Installing: $expected' on stdout (stdout: $(cat "$LAST_STDOUT_FILE"))"
  fi
}

# --- Case 1: packages wins, verbatim ----------------------------------------
# `packages` overrides both `version` and `extras`, and is passed through
# word-for-word without a `dblift[...]` specifier being synthesised.

run_case "dblift[mysql]==2.1.0 psycopg[binary]" "9.9.9" "postgresql"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case1: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case1" "install dblift[mysql]==2.1.0 psycopg[binary]"
assert_installing_line "case1" "dblift[mysql]==2.1.0 psycopg[binary]"

# --- Case 2: no packages -> dblift[<extras>], with ==<version> when set -----

run_case "" "3.9.0" "mysql"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case2: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case2" "install dblift[mysql]==3.9.0"
assert_installing_line "case2" "dblift[mysql]==3.9.0"

# --- Case 3: no packages, no version -> unpinned dblift[<extras>] -----------

run_case "" "" "postgresql"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case3: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case3" "install dblift[postgresql]"
assert_installing_line "case3" "dblift[postgresql]"

# --- Case 4: index-url is passed to pip on either resolution path -----------

run_case "" "" "postgresql" "https://pypi.example.invalid/simple"
if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case4a: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case4a" "install --index-url https://pypi.example.invalid/simple dblift[postgresql]"

run_case "dblift" "" "" "https://pypi.example.invalid/simple"
if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case4b: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case4b" "install --index-url https://pypi.example.invalid/simple dblift"

# --- Case 5: whitespace-only packages falls back to the extras specifier ----
# Regression test: `read -ra` on whitespace-only input yields a zero-element
# array; expanding that under `set -u` on bash 3.2 (the macOS-runner version)
# aborts with "unbound variable" unless the empty-result case is handled.

run_case " " "" "postgresql"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case5: expected exit 0 (whitespace-only packages must fall back to extras, not crash), got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case5" "install dblift[postgresql]"

# --- Case 6: pip failure is not swallowed -----------------------------------

failing_pip="$tmp_root/pip-failing.sh"
cat > "$failing_pip" <<'STUB'
#!/bin/bash
echo "pip stub: simulated failure" >&2
exit 3
STUB
chmod +x "$failing_pip"

set +e
env \
  INPUT_PACKAGES="" \
  INPUT_VERSION="" \
  INPUT_EXTRAS="postgresql" \
  INPUT_INDEX_URL="" \
  PIP_BIN="$failing_pip" \
  bash "$install_script" > "$tmp_root/stdout-fail" 2> "$tmp_root/stderr-fail"
fail_exit=$?
set -e

if [ "$fail_exit" -ne 3 ]; then
  fail "case6: expected install.sh to exit with pip's status 3, got $fail_exit"
fi
if ! grep -qF 'simulated failure' "$tmp_root/stderr-fail"; then
  fail "case6: expected pip's stderr to be surfaced (stderr: $(cat "$tmp_root/stderr-fail"))"
fi

# --- Case 7: multiline packages -> every line installed ---------------------
# A `packages: |` block is natural YAML; `read -ra` alone stops at the first
# newline and would silently drop every package after line 1.

run_case "$(printf 'dblift[mysql]==2.1.0\npsycopg[binary]')" "" ""

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case7: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case7" "install dblift[mysql]==2.1.0 psycopg[binary]"

# --- Case 8: whitespace in extras/version is stripped, not word-split -------
# `extras: 'postgresql, mysql'` must build dblift[postgresql,mysql], not
# fracture into two bogus pip arguments.

run_case "" " 3.9.0 " "postgresql, mysql"

if [ "$LAST_EXIT" -ne 0 ]; then
  fail "case8: expected exit 0, got $LAST_EXIT (stderr: $(cat "$LAST_STDERR_FILE"))"
fi
assert_pip_argv "case8" "install dblift[postgresql,mysql]==3.9.0"

if [ "$failures" -eq 0 ]; then
  echo "test-install.sh: all cases passed"
fi

exit "$failures"

#!/usr/bin/env bash
set -uo pipefail
OMAMAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMAMAC_BIN="$OMAMAC_ROOT/bin/omamac"
FAILURES=0

fail() { printf '  FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected '$1', got '$2'"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "expected '$1' to contain '$2'" ;; esac
}

assert_file_eq() {
  diff -u "$1" "$2" >/dev/null || { fail "files differ: $1 vs $2"; diff -u "$1" "$2" >&2 || true; }
}

setup_tmp_home() {
  TMPDIR_TEST="$(mktemp -d)"
  export HOME="$TMPDIR_TEST/home"
  export OMAMAC_STATE="$HOME/.local/state/omamac"
  export OMAMAC_CACHE="$HOME/.cache/omamac"
  mkdir -p "$HOME/.config" "$OMAMAC_STATE" "$OMAMAC_CACHE"
}

run_tests() {
  local fn
  # A fresh HOME per test. Without this, tests share state and only pass
  # because `declare -F` happens to sort them favourably.
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    printf '  %s\n' "$fn"
    setup_tmp_home
    (set +e; "$fn")
    rm -rf "$TMPDIR_TEST"
  done
  [ "$FAILURES" -eq 0 ] || exit 1
}

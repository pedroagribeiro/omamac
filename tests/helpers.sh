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

# Parse the file with whatever Lua front-end exists. `loadfile` only PARSES —
# it never executes the colorscheme — and `cq` is what turns a parse failure into
# a real exit code (plain `-c q` exits 0 even after the error prints). Returns
# 127 when no parser exists at all, which the test treats as a failure rather
# than a skip: a generated file nothing ever parses is the gap this guards.
lua_parse_check() {
  if command -v luac >/dev/null 2>&1; then luac -p "$1"; return $?; fi
  if command -v luajit >/dev/null 2>&1; then luajit -bl "$1" >/dev/null; return $?; fi
  if command -v lua >/dev/null 2>&1; then lua -e "assert(loadfile('$1'))"; return $?; fi
  if command -v nvim >/dev/null 2>&1; then
    nvim --headless -c "lua if not loadfile('$1') then vim.cmd('cq') end" -c q >/dev/null 2>&1
    return $?
  fi
  return 127
}

# Actually EXECUTES a Lua script file (unlike lua_parse_check, which only
# parses) with whatever fully-executing front-end exists, and prints its
# stdout. Same discovery order/spirit as lua_parse_check (luac is omitted —
# it never executes) so this fails loudly rather than silently skipping when
# nothing can run it. Returns the interpreter's exit code, or 127 if no
# runnable Lua exists — callers must treat 127 as a failure, not a skip.
lua_run() {
  if command -v lua >/dev/null 2>&1; then lua "$1"; return $?; fi
  if command -v luajit >/dev/null 2>&1; then luajit "$1"; return $?; fi
  if command -v nvim >/dev/null 2>&1; then
    nvim --headless \
      -c "lua local ok, err = pcall(dofile, '$1'); if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cq') end" \
      -c q
    return $?
  fi
  return 127
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
    # NOT `(set +e; "$fn")` — a subshell discards fail()'s FAILURES increment,
    # which makes the exit-code gate below always pass. `set -e` is never
    # enabled here, so a failing test cannot abort the loop anyway.
    "$fn"
    rm -rf "$TMPDIR_TEST"
  done
  [ "$FAILURES" -eq 0 ] || exit 1
}

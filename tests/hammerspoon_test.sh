#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
HOST="$OMAMAC_ROOT/hammerspoon/omamac.lua"

test_host_parses() {
  [ -f "$HOST" ] || { fail "hammerspoon/omamac.lua missing"; return; }
  local rc; lua_parse_check "$HOST"; rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no Lua parser available — cannot verify the host"
  else
    assert_eq 0 "$rc" "hammerspoon/omamac.lua must parse"
  fi
}

test_binds_both_hotkeys() {
  local src; src=$(cat "$HOST")
  # cmd+alt+space opens the menu; cmd+ctrl+space cycles the wallpaper.
  assert_contains "$src" '{ "cmd", "alt" }, "space"'
  assert_contains "$src" '{ "cmd", "ctrl" }, "space"'
}

test_speaks_the_page_contract() {
  local src; src=$(cat "$HOST")
  # These four names are the page↔host contract from Task 14. If the page is
  # rewritten and one is dropped, the menu renders but does nothing.
  assert_contains "$src" "menu-data"
  assert_contains "$src" "omamacSetPreview"
  assert_contains "$src" 'b.action == "apply"'
  assert_contains "$src" 'b.action == "preview"'
  assert_contains "$src" 'b.action == "close"'
  # The page is injected as window.OMAMAC ahead of the file's own script.
  assert_contains "$src" "window.OMAMAC"
}

test_resolves_omamac_bin_with_wrapped_fallback_chain() {
  local src; src=$(cat "$HOST")
  # OMAMAC_BIN (set by the generated init.lua alongside OMAMAC_DIR) must be
  # preferred — it points at the WRAPPED binary flake.nix's makeWrapper
  # prefixes with jq/curl/fontconfig/bash on PATH. The unwrapped
  # OMAMAC .. "/bin/omamac" fallback stays for non-Nix / test invocations.
  assert_contains "$src" "OMAMAC_BIN_PATH = OMAMAC_BIN"
  assert_contains "$src" 'os.getenv("OMAMAC_BIN")'
  assert_contains "$src" 'OMAMAC .. "/bin/omamac"'
}

test_run_and_runasync_invoke_the_resolved_binary() {
  local src; src=$(cat "$HOST")
  # run() and runAsync() must both shell out to OMAMAC_BIN_PATH, not build
  # "OMAMAC .. /bin/omamac" directly at the call site — that would bypass the
  # OMAMAC_BIN preference above entirely.
  local n; n=$(printf '%s' "$src" | grep -c 'shquote(OMAMAC_BIN_PATH)')
  assert_eq 2 "$n" "run() and runAsync() must both invoke the resolved OMAMAC_BIN_PATH"
}

run_tests

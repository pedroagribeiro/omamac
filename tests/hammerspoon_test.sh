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

run_tests

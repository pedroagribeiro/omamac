#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_writes_colorscheme_with_palette_colors() {
  export OMAMAC_NVIM="true"
  "$OMAMAC_ROOT/render/nvim" "$OMAMAC_ROOT/tests/fixtures/dark" "$OMAMAC_STATE"
  local out; out=$(cat "$OMAMAC_STATE/current/omamac.lua")
  assert_contains "$out" 'vim.g.colors_name = "omamac"'
  assert_contains "$out" "#1a1b26"
  assert_contains "$out" "Normal"
  assert_contains "$out" "termguicolors"
}

test_is_valid_lua() {
  export OMAMAC_NVIM="true"
  "$OMAMAC_ROOT/render/nvim" "$OMAMAC_ROOT/tests/fixtures/dark" "$OMAMAC_STATE"
  if command -v luac >/dev/null 2>&1; then
    luac -p "$OMAMAC_STATE/current/omamac.lua" || fail "generated lua does not parse"
  fi
}

test_sets_background_option_from_luminance() {
  export OMAMAC_NVIM="true"
  "$OMAMAC_ROOT/render/nvim" "$OMAMAC_ROOT/tests/fixtures/light" "$OMAMAC_STATE"
  assert_contains "$(cat "$OMAMAC_STATE/current/omamac.lua")" 'vim.o.background = "light"'
}

test_missing_colors_toml_exits_nonzero() {
  export OMAMAC_NVIM="true"
  mkdir -p "$TMPDIR_TEST/empty"
  local rc; "$OMAMAC_ROOT/render/nvim" "$TMPDIR_TEST/empty" "$OMAMAC_STATE" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme dir with no colors.toml must signal failure"
}

run_tests

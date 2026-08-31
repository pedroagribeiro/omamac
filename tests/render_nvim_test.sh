#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_writes_colorscheme_with_palette_colors() {
  export OMAMAC_NVIM="true"
  "$OMAMAC_ROOT/render/nvim" "$OMAMAC_ROOT/tests/fixtures/dark" "$OMAMAC_STATE"
  local out; out=$(cat "$OMAMAC_STATE/current/omamac.lua")
  assert_contains "$out" 'vim.g.colors_name = "omamac"'
  assert_contains "$out" 'bg = "#1a1b26"'
  assert_contains "$out" 'fg = "#a9b1d6"'
  assert_contains "$out" 'cursor = "#c0caf5"'
  # selection_background/selection_foreground alias to selection/foreground;
  # color0/color8 alias to muted — tokyo-night's real colors.toml has none
  # of these keys literally.
  assert_contains "$out" 'sel_bg = "#292e42"'
  assert_contains "$out" 'sel_fg = "#a9b1d6"'
  assert_contains "$out" 'black = "#414868"'
  assert_contains "$out" 'red = "#f7768e"'
  assert_contains "$out" 'green = "#9ece6a"'
  assert_contains "$out" 'yellow = "#e0af68"'
  assert_contains "$out" 'blue = "#7aa2f7"'
  assert_contains "$out" 'magenta = "#ad8ee6"'
  assert_contains "$out" 'cyan = "#449dab"'
  assert_contains "$out" 'grey = "#414868"'
  assert_contains "$out" "Normal"
  assert_contains "$out" "termguicolors"
}

test_is_valid_lua() {
  export OMAMAC_NVIM="true"
  "$OMAMAC_ROOT/render/nvim" "$OMAMAC_ROOT/tests/fixtures/dark" "$OMAMAC_STATE"
  local rc; lua_parse_check "$OMAMAC_STATE/current/omamac.lua"; rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no Lua parser available (luac/luajit/lua/nvim) — cannot verify the generated Lua"
  else
    assert_eq 0 "$rc" "generated lua must parse"
  fi
}

test_sets_background_option_for_light_theme() {
  # catppuccin-latte's colors.toml has an explicit `mode = "light"` key now,
  # so this exercises omamac_is_light's mode path, not luminance directly —
  # the luminance fallback is covered separately in tests/colors_test.sh.
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

test_missing_colour_key_warns_and_never_emits_bare_hash() {
  export OMAMAC_NVIM="true"
  local partial="$TMPDIR_TEST/partial"
  mkdir -p "$partial"
  # color1 has no literal key of its own — it resolves via omamac_alias to
  # `red`, so stripping THAT line is what makes it missing. The trailing
  # space keeps this from also matching `bright_red`.
  grep -v '^red ' "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" > "$partial/colors.toml"
  local err; err=$("$OMAMAC_ROOT/render/nvim" "$partial" "$OMAMAC_STATE" 2>&1)
  assert_contains "$err" "missing colour 'color1'"
  # `red = "#"` is VALID Lua, so a parse check cannot catch this — assert the
  # fallback value explicitly.
  assert_contains "$(cat "$OMAMAC_STATE/current/omamac.lua")" 'red = "#000000"'
  case "$(cat "$OMAMAC_STATE/current/omamac.lua")" in
    *'"#"'*) fail "emitted a bare '#' for the missing colour" ;;
  esac
}

run_tests

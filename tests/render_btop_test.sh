#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

test_writes_theme_file() {
  local root="$TMPDIR_TEST/b1"
  "$OMAMAC_ROOT/render/btop" "$THEME" "$root"
  local out; out=$(cat "$root/btop/themes/omamac.theme")
  # One assertion per DISTINCT source colour key the renderer consumes (11 of
  # them), not per emitted line. Sampling two would let a mutant that swaps
  # color2/color5 or drops selection_* pass unnoticed.
  assert_contains "$out" 'theme[main_bg]="#1a1b26"'       # background
  assert_contains "$out" 'theme[main_fg]="#a9b1d6"'       # foreground
  assert_contains "$out" 'theme[hi_fg]="#7aa2f7"'         # color4
  assert_contains "$out" 'theme[selected_bg]="#7aa2f7"'   # selection_background
  assert_contains "$out" 'theme[selected_fg]="#c0caf5"'   # selection_foreground
  assert_contains "$out" 'theme[inactive_fg]="#444b6a"'   # color8
  assert_contains "$out" 'theme[proc_misc]="#449dab"'     # color6
  assert_contains "$out" 'theme[mem_box]="#9ece6a"'       # color2
  assert_contains "$out" 'theme[net_box]="#ad8ee6"'       # color5
  assert_contains "$out" 'theme[proc_box]="#e0af68"'      # color3
  assert_contains "$out" 'theme[temp_end]="#f7768e"'      # color1
}

test_creates_conf_when_absent() {
  local root="$TMPDIR_TEST/b2"
  "$OMAMAC_ROOT/render/btop" "$THEME" "$root"
  assert_contains "$(cat "$root/btop/btop.conf")" 'color_theme = "omamac"'
}

test_replaces_existing_key_without_duplicating() {
  local root="$TMPDIR_TEST/b3"
  mkdir -p "$root/btop"
  printf 'color_theme = "gruvbox"\nvim_keys = True\n' > "$root/btop/btop.conf"
  "$OMAMAC_ROOT/render/btop" "$THEME" "$root"
  assert_eq 1 "$(grep -c 'color_theme' "$root/btop/btop.conf")"
  assert_contains "$(cat "$root/btop/btop.conf")" 'color_theme = "omamac"'
  assert_contains "$(cat "$root/btop/btop.conf")" 'vim_keys = True'
}

test_missing_colors_toml_exits_nonzero() {
  mkdir -p "$TMPDIR_TEST/empty"
  local rc; "$OMAMAC_ROOT/render/btop" "$TMPDIR_TEST/empty" "$TMPDIR_TEST/b4" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme dir with no colors.toml must signal failure"
}

test_missing_colour_key_warns_and_never_emits_bare_hash() {
  local root="$TMPDIR_TEST/b5" partial="$TMPDIR_TEST/partial-btop"
  mkdir -p "$partial"
  grep -v '^color1 ' "$THEME/colors.toml" > "$partial/colors.toml"
  local err; err=$("$OMAMAC_ROOT/render/btop" "$partial" "$root" 2>&1)
  assert_contains "$err" "missing colour 'color1'"
  case "$(cat "$root/btop/themes/omamac.theme")" in
    *'="#"'*) fail "emitted a bare '#' for the missing colour" ;;
  esac
}

run_tests

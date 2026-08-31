#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

test_writes_theme_file() {
  local root="$TMPDIR_TEST/b1"
  "$OMAMAC_ROOT/render/btop" "$THEME" "$root"
  local out; out=$(cat "$root/btop/themes/omamac.theme")
  assert_contains "$out" 'theme[main_bg]="#1a1b26"'
  assert_contains "$out" 'theme[main_fg]="#a9b1d6"'
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

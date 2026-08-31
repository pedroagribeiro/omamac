#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

test_writes_full_palette() {
  local root="$TMPDIR_TEST/cfg1"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local f="$root/ghostty/themes/omamac"
  assert_eq 16 "$(grep -c '^palette = ' "$f")"
  assert_contains "$(cat "$f")" "palette = 0=#32344a"
  assert_contains "$(cat "$f")" "palette = 15=#acb0d0"
}

test_writes_surface_colors() {
  local root="$TMPDIR_TEST/cfg2"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local out; out=$(cat "$root/ghostty/themes/omamac")
  assert_contains "$out" "background = #1a1b26"
  assert_contains "$out" "foreground = #a9b1d6"
  assert_contains "$out" "cursor-color = #c0caf5"
  assert_contains "$out" "selection-background = #7aa2f7"
}

test_conf_selects_theme_and_omits_font_when_none_given() {
  local root="$TMPDIR_TEST/cfg3"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local out; out=$(cat "$root/ghostty/omamac.conf")
  assert_contains "$out" "theme = omamac"
  case "$out" in *font-family*) fail "must not emit font-family when none given" ;; esac
}

test_conf_resets_font_list_before_setting_font() {
  local root="$TMPDIR_TEST/cfg4"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root" "JetBrainsMono Nerd Font"
  local first second
  first=$(grep -n 'font-family' "$root/ghostty/omamac.conf" | head -1)
  second=$(grep -n 'font-family' "$root/ghostty/omamac.conf" | sed -n 2p)
  assert_contains "$first" 'font-family = ""'
  assert_contains "$second" 'font-family = "JetBrainsMono Nerd Font"'
}

test_is_idempotent() {
  local root="$TMPDIR_TEST/cfg5"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root" "Menlo Nerd Font"
  cp "$root/ghostty/omamac.conf" "$TMPDIR_TEST/first.conf"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root" "Menlo Nerd Font"
  assert_file_eq "$TMPDIR_TEST/first.conf" "$root/ghostty/omamac.conf"
}

run_tests

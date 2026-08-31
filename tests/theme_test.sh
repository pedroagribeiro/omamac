#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_themes() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night" "$OMAMAC_THEMES_DIR/catppuccin-latte"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$OMAMAC_THEMES_DIR/catppuccin-latte/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true"        # never signal a real process from tests
  export OMAMAC_OSASCRIPT="true"
}

test_list_is_sorted() {
  setup_themes
  assert_eq "catppuccin-latte
tokyo-night" "$("$OMAMAC_BIN" theme --list)"
}

test_current_is_empty_before_any_set() {
  setup_themes
  assert_eq "" "$("$OMAMAC_BIN" theme --current)"
}

test_set_records_current() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_eq "tokyo-night" "$("$OMAMAC_BIN" theme --current)"
}

test_set_renders_ghostty() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/themes/omamac")" "background = #1a1b26"
}

test_set_applies_stored_font() {
  setup_themes
  omamac_state_set() { :; }   # not used here; font comes from state file
  mkdir -p "$OMAMAC_STATE"; printf 'JetBrainsMono Nerd Font\n' > "$OMAMAC_STATE/font"
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf")" 'font-family = "JetBrainsMono Nerd Font"'
}

test_unknown_theme_exits_1_and_leaves_current_untouched() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  local rc; "$OMAMAC_BIN" theme no-such-theme >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc"
  assert_eq "tokyo-night" "$("$OMAMAC_BIN" theme --current)"
}

test_succeeds_when_ghostty_not_running() {
  setup_themes
  local rc; "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "a theme switch must succeed with no Ghostty running"
}

run_tests

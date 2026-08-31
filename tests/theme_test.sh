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
  # Stub the process lookup too. Without this the tests read the REAL process
  # table, so which branch of ghostty_reload runs depends on whether the
  # developer happens to have Ghostty open.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  printf '#!/usr/bin/env bash\nprintf "  501 /Applications/Ghostty.app/Contents/MacOS/ghostty\\n"\n' \
    > "$TMPDIR_TEST/ps-running"
  chmod +x "$TMPDIR_TEST/ps-none" "$TMPDIR_TEST/ps-running"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
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
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
  local out rc
  out=$("$OMAMAC_BIN" theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc" "a theme switch must succeed with no Ghostty running"
  assert_contains "$out" "not running"
}

test_reports_reload_when_ghostty_is_running() {
  setup_themes
  export OMAMAC_PS="$TMPDIR_TEST/ps-running"
  local out rc
  out=$("$OMAMAC_BIN" theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_contains "$out" "reloaded"
}

run_tests

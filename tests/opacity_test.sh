#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Terminal transparency is a USER PREFERENCE, not a theme property. Omarchy's
# ghostty template sets colours only, and its "Transparency" menu entry drives
# the Quickshell bar (omarchy-bar transparent toggle), not the terminal. So
# there is nothing upstream to port here: this follows omamac's own pattern for
# font family and size — recorded in state, written into omamac.conf, and
# surviving every theme switch.
setup_opacity() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/ghostty"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"; chmod +x "$TMPDIR_TEST/ps-none"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
  export OMAMAC_CLAUDE_DIR="$TMPDIR_TEST/claude"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
  CONF="$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf"
}

test_list_is_a_percentage_range() {
  setup_opacity
  local out; out=$("$OMAMAC_BIN" opacity --list)
  assert_eq "50" "$(printf '%s\n' "$out" | head -1)"
  assert_eq "100" "$(printf '%s\n' "$out" | tail -1)"
  assert_eq 11 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "50..100 in steps of 5"
}

# Ghostty's own default is background-opacity = 1, so with nothing declared
# anywhere the honest answer is 100 — not empty. That makes the picker mark a
# row the first time it is opened.
test_current_is_100_when_nothing_declares_it() {
  setup_opacity
  printf 'font-size = 16\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "100" "$("$OMAMAC_BIN" opacity --current)"
}

test_current_reads_the_users_ghostty_config_before_anything_is_chosen() {
  setup_opacity
  printf 'background-opacity = 0.8\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "80" "$("$OMAMAC_BIN" opacity --current)"
}

test_current_prefers_state_once_chosen() {
  setup_opacity
  printf 'background-opacity = 0.8\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  "$OMAMAC_BIN" opacity 65 >/dev/null 2>&1
  assert_eq "65" "$("$OMAMAC_BIN" opacity --current)"
}

test_set_writes_a_decimal_ghostty_understands() {
  setup_opacity
  "$OMAMAC_BIN" opacity 90 >/dev/null 2>&1
  # Ghostty takes a 0..1 float, but the menu talks in percentages — showing
  # "0.9" in a picker would be worse than showing "90".
  assert_contains "$(cat "$CONF")" "background-opacity = 0.90"
}

test_full_opacity_is_still_written_so_it_can_override_a_transparent_config() {
  setup_opacity
  # Choosing 100 must emit the line, not omit it: the whole point is to win
  # over a config that sets a lower value. Omitting it would silently leave
  # the terminal transparent.
  "$OMAMAC_BIN" opacity 100 >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "background-opacity = 1.00"
}

test_no_opacity_line_until_one_is_chosen() {
  setup_opacity
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  case "$(cat "$CONF")" in
    *background-opacity*) fail "omamac.conf declared an opacity that was never chosen" ;;
  esac
}

test_opacity_survives_a_theme_switch() {
  setup_opacity
  "$OMAMAC_BIN" opacity 75 >/dev/null 2>&1
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "background-opacity = 0.75" \
    "a theme switch must not drop the chosen opacity"
}

test_out_of_range_and_non_numeric_are_refused() {
  setup_opacity
  local rc
  for bad in 49 101 0 -5 abc 0.9; do
    "$OMAMAC_BIN" opacity "$bad" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || fail "opacity '$bad' should have been refused, exited $rc"
  done
  [ -f "$OMAMAC_STATE/opacity" ] && fail "a refused value must not be recorded"
}

# Same discipline as font.size: unset and empty mean different things, because
# unset is what keeps omamac out of the user's own background-opacity.
test_failed_render_reverts_to_unset() {
  setup_opacity
  chmod 500 "$OMAMAC_CONFIG_ROOT/ghostty" 2>/dev/null
  printf 'broken\n' > "$OMAMAC_STATE/theme.name"
  local rc
  "$OMAMAC_BIN" opacity 70 >/dev/null 2>&1; rc=$?
  chmod 700 "$OMAMAC_CONFIG_ROOT/ghostty" 2>/dev/null
  assert_eq 1 "$rc"
  [ -f "$OMAMAC_STATE/opacity" ] && \
    fail "a rolled-back opacity must be UNSET, not empty"
}

test_menu_data_exposes_the_opacity_level() {
  setup_opacity
  printf 'background-opacity = 0.9\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  local json; json=$("$OMAMAC_BIN" menu-data)
  assert_eq "90" "$(printf '%s' "$json" | jq -r '.opacity.current')"
  assert_eq 11 "$(printf '%s' "$json" | jq '.opacity.options | length')"
}

# `sed` on a nonexistent file fails, and under `set -o pipefail` that took the
# whole command's exit status with it — so this returned 1 on any machine with
# no Ghostty config at all. It also made the "empty argument" case above look
# like validation when it was really this failure.
test_current_succeeds_when_there_is_no_ghostty_config() {
  setup_opacity
  rm -f "$OMAMAC_CONFIG_ROOT/ghostty/config"
  rm -f "$OMAMAC_STATE/opacity"
  local out rc
  out=$("$OMAMAC_BIN" opacity --current 2>&1); rc=$?
  assert_eq 0 "$rc" "nothing declared anywhere is a valid state, not an error"
  assert_eq "100" "$out"
}

run_tests

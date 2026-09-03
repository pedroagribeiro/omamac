#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# window-padding and background-blur follow omamac-opacity's shape exactly:
# recorded in state, written into omamac.conf, surviving theme switches. What
# is worth pinning is what differs — padding drives TWO Ghostty keys, and blur
# uses the modern `background-blur = <n>` rather than the legacy radius option.
setup_gs() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/ghostty"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps"; chmod +x "$TMPDIR_TEST/ps"
  export OMAMAC_PS="$TMPDIR_TEST/ps" OMAMAC_CLAUDE_DIR="$TMPDIR_TEST/claude"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
  CONF="$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf"
}

test_lists_are_the_expected_ranges() {
  setup_gs
  assert_eq "0" "$("$OMAMAC_BIN" padding --list | head -1)"
  assert_eq "30" "$("$OMAMAC_BIN" padding --list | tail -1)"
  assert_eq "0" "$("$OMAMAC_BIN" blur --list | head -1)"
  assert_eq "40" "$("$OMAMAC_BIN" blur --list | tail -1)"
}

# Ghostty has separate x and y keys; omamac offers one padding, so both must
# move. Writing only one gives a window padded on one axis, which reads as a
# rendering bug rather than a setting.
test_padding_drives_both_axes() {
  setup_gs
  "$OMAMAC_BIN" padding 18 >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "window-padding-x = 18"
  assert_contains "$(cat "$CONF")" "window-padding-y = 18"
}

# `background-blur-radius` is a legacy alias absent from Ghostty's current
# option set; `background-blur = <n>` both enables the blur and sets its
# radius, and is what a modern Ghostty documents.
test_blur_uses_the_modern_numeric_option() {
  setup_gs
  "$OMAMAC_BIN" blur 25 >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "background-blur = 25"
  case "$(cat "$CONF")" in
    *background-blur-radius*) fail "the legacy background-blur-radius must not be emitted" ;;
  esac
}

test_current_reads_the_users_config_before_anything_is_chosen() {
  setup_gs
  printf 'window-padding-x = 8\nwindow-padding-y = 8\nbackground-blur = 30\n' \
    > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "8" "$("$OMAMAC_BIN" padding --current)"
  assert_eq "30" "$("$OMAMAC_BIN" blur --current)"
}

test_current_falls_back_to_ghostty_defaults() {
  setup_gs
  rm -f "$OMAMAC_CONFIG_ROOT/ghostty/config"
  local out rc
  out=$("$OMAMAC_BIN" padding --current 2>&1); rc=$?
  assert_eq 0 "$rc" "nothing declared anywhere is a valid state, not an error"
  assert_eq "12" "$out"
}

test_neither_is_written_until_chosen() {
  setup_gs
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  case "$(cat "$CONF")" in
    *window-padding*) fail "omamac.conf declared a padding that was never chosen" ;;
  esac
  case "$(cat "$CONF")" in
    *background-blur*) fail "omamac.conf declared a blur that was never chosen" ;;
  esac
}

test_both_survive_a_theme_switch() {
  setup_gs
  "$OMAMAC_BIN" padding 6 >/dev/null 2>&1
  "$OMAMAC_BIN" blur 10 >/dev/null 2>&1
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "window-padding-x = 6"
  assert_contains "$(cat "$CONF")" "background-blur = 10"
}

test_out_of_range_and_non_numeric_are_refused() {
  setup_gs
  local rc
  for bad in 31 -2 abc 4.5; do
    "$OMAMAC_BIN" padding "$bad" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || fail "padding '$bad' should have been refused, exited $rc"
  done
  for bad in 41 -5 abc; do
    "$OMAMAC_BIN" blur "$bad" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || fail "blur '$bad' should have been refused, exited $rc"
  done
  [ -f "$OMAMAC_STATE/padding" ] && fail "a refused padding must not be recorded"
  [ -f "$OMAMAC_STATE/blur" ] && fail "a refused blur must not be recorded"
}

# Zero is meaningful for both — no padding, no blur — so it must be written
# rather than treated as "unset" and omitted.
test_zero_is_written_not_treated_as_unset() {
  setup_gs
  "$OMAMAC_BIN" padding 0 >/dev/null 2>&1
  "$OMAMAC_BIN" blur 0 >/dev/null 2>&1
  assert_contains "$(cat "$CONF")" "window-padding-x = 0"
  assert_contains "$(cat "$CONF")" "background-blur = 0"
}

run_tests

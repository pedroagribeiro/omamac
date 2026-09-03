#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_size_env() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/ghostty"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  chmod +x "$TMPDIR_TEST/ps-none"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
  export OMAMAC_CLAUDE_DIR="$TMPDIR_TEST/claude"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

test_list_is_a_contiguous_point_range() {
  setup_size_env
  local out; out=$("$OMAMAC_BIN" font-size --list)
  assert_eq "10" "$(printf '%s\n' "$out" | head -1)"
  assert_eq "24" "$(printf '%s\n' "$out" | tail -1)"
  assert_eq 15 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
}

# Before omamac has been asked for a size, the picker must still be able to
# mark the row that is actually in effect — which means reading it out of the
# user's own Ghostty config rather than reporting nothing.
test_current_falls_back_to_the_users_ghostty_config() {
  setup_size_env
  printf 'font-family = "Menlo"\nfont-size = 16\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "16" "$("$OMAMAC_BIN" font-size --current)"
}

test_current_prefers_state_once_a_size_has_been_chosen() {
  setup_size_env
  printf 'font-size = 16\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  "$OMAMAC_BIN" font-size 13 >/dev/null 2>&1
  assert_eq "13" "$("$OMAMAC_BIN" font-size --current)"
}

# Ghostty applies the LAST value it sees, so a config declaring the key more
# than once must be read the same way.
test_current_takes_the_last_declaration_like_ghostty_does() {
  setup_size_env
  printf 'font-size = 12\nfont-size = 18\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "18" "$("$OMAMAC_BIN" font-size --current)"
}

test_current_is_empty_when_nothing_declares_a_size() {
  setup_size_env
  printf 'font-family = "Menlo"\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_eq "" "$("$OMAMAC_BIN" font-size --current)"
}

test_set_writes_the_size_into_the_ghostty_include() {
  setup_size_env
  "$OMAMAC_BIN" font-size 14 >/dev/null 2>&1
  local conf="$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf"
  [ -f "$conf" ] || { fail "no omamac.conf written"; return; }
  assert_contains "$(cat "$conf")" "font-size = 14"
}

# omamac must not invent a size for someone who never picked one: with nothing
# in state the include has to stay silent on font-size, or it would override
# whatever the user's own config declares.
test_no_font_size_line_until_one_is_chosen() {
  setup_size_env
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  local conf="$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf"
  case "$(cat "$conf")" in
    *font-size*) fail "omamac.conf declared a font-size that was never chosen" ;;
  esac
}

test_size_survives_a_theme_switch() {
  setup_size_env
  "$OMAMAC_BIN" font-size 21 >/dev/null 2>&1
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf")" "font-size = 21" \
    "a theme switch must not drop the chosen size"
}

test_out_of_range_and_non_numeric_are_refused() {
  setup_size_env
  local out rc
  for bad in 9 25 0 -3 abc 14.5; do
    out=$("$OMAMAC_BIN" font-size "$bad" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "font-size '$bad' should have been refused, exited $rc"
  done
  # ...and none of them may have been recorded.
  assert_eq "" "$(cat "$OMAMAC_STATE/font.size" 2>/dev/null)"
}

# Same speculative-write discipline as omamac-font: the render reads the size
# back out of state, so a failed render must leave no trace of it.
test_failed_render_reverts_to_unset_not_to_empty() {
  setup_size_env
  # An unwritable config root makes render/ghostty fail.
  chmod 500 "$OMAMAC_CONFIG_ROOT/ghostty" 2>/dev/null
  printf 'broken\n' > "$OMAMAC_STATE/theme.name"
  local rc
  "$OMAMAC_BIN" font-size 14 >/dev/null 2>&1; rc=$?
  chmod 700 "$OMAMAC_CONFIG_ROOT/ghostty" 2>/dev/null
  assert_eq 1 "$rc" "a failed apply must report failure"
  [ -f "$OMAMAC_STATE/font.size" ] && \
    fail "a rolled-back size must be UNSET, not an empty file — unset is what keeps omamac out of the user's own font-size"
}

test_menu_data_exposes_the_size_level() {
  setup_size_env
  printf 'font-size = 16\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  local json; json=$("$OMAMAC_BIN" menu-data)
  assert_eq "16" "$(printf '%s' "$json" | jq -r '.fontSize.current')"
  assert_eq 15 "$(printf '%s' "$json" | jq '.fontSize.options | length')"
  # The colours block must have survived sharing a jq variable namespace.
  assert_contains "$(printf '%s' "$json" | jq -r '.colors.selection_background')" "#"
}

# `sed` on a nonexistent file fails, and under `set -o pipefail` that took the
# whole command's exit status with it — so this returned 1 on any machine with
# no Ghostty config at all. It also made the "empty argument" case above look
# like validation when it was really this failure.
test_current_succeeds_when_there_is_no_ghostty_config() {
  setup_size_env
  rm -f "$OMAMAC_CONFIG_ROOT/ghostty/config"
  rm -f "$OMAMAC_STATE/font.size"
  local out rc
  out=$("$OMAMAC_BIN" font-size --current 2>&1); rc=$?
  assert_eq 0 "$rc" "nothing declared anywhere is a valid state, not an error"
  assert_eq "" "$out"
}

run_tests

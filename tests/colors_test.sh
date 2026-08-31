#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$OMAMAC_ROOT/lib/colors.sh"
DARK="$OMAMAC_ROOT/tests/fixtures/dark/colors.toml"
LIGHT="$OMAMAC_ROOT/tests/fixtures/light/colors.toml"

test_reads_named_key_without_hash() {
  assert_eq "1a1b26" "$(omamac_color "$DARK" background)"
  assert_eq "a9b1d6" "$(omamac_color "$DARK" foreground)"
}

test_reads_numbered_palette_keys() {
  assert_eq "32344a" "$(omamac_color "$DARK" color0)"
  assert_eq "acb0d0" "$(omamac_color "$DARK" color15)"
}

test_color1_does_not_match_color15() {
  # A sloppy regex anchored only at the start would return color15's value here.
  assert_eq "f7768e" "$(omamac_color "$DARK" color1)"
}

test_missing_key_is_empty_and_succeeds() {
  local v rc
  v=$(omamac_color "$DARK" nonexistent); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$v"
}

test_uppercase_hex_is_normalised_to_lowercase() {
  local f="$TMPDIR_TEST/up.toml"
  printf 'background = "#FFFCF0"\n' > "$f"
  assert_eq "fffcf0" "$(omamac_color "$f" background)"
}

test_dark_background_is_not_light() {
  omamac_is_light "$DARK" && fail "tokyo-night must be dark"
}

test_light_background_is_light() {
  omamac_is_light "$LIGHT" || fail "catppuccin-latte must be light"
}

run_tests

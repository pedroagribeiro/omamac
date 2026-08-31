#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$OMAMAC_ROOT/lib/colors.sh"

test_expected_themes_are_vendored() {
  local t
  for t in tokyo-night catppuccin catppuccin-latte gruvbox nord everforest \
           rose-pine kanagawa matte-black osaka-jade ristretto miasma; do
    [ -f "$OMAMAC_ROOT/themes/$t/colors.toml" ] || fail "missing theme: $t"
  done
}

test_every_theme_has_a_full_palette() {
  local d i
  for d in "$OMAMAC_ROOT"/themes/*/; do
    for i in $(seq 0 15); do
      [ -n "$(omamac_color "$d/colors.toml" "color$i")" ] || fail "$(basename "$d") missing color$i"
    done
    [ -n "$(omamac_color "$d/colors.toml" background)" ] || fail "$(basename "$d") missing background"
    [ -n "$(omamac_color "$d/colors.toml" foreground)" ] || fail "$(basename "$d") missing foreground"
  done
}

test_both_light_and_dark_themes_exist() {
  local light=0 dark=0 d
  for d in "$OMAMAC_ROOT"/themes/*/; do
    if omamac_is_light "$d/colors.toml"; then light=$((light + 1)); else dark=$((dark + 1)); fi
  done
  [ "$light" -ge 1 ] || fail "expected at least one light theme"
  [ "$dark" -ge 1 ] || fail "expected at least one dark theme"
}

# Guards against a sync that vendors exactly the upstream set and nothing
# more/less. A partial or padded vendoring would slip past the subset check
# in test_expected_themes_are_vendored above.
test_exactly_22_themes_are_vendored() {
  local count
  count=$(find "$OMAMAC_ROOT/themes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" -eq 22 ] || fail "expected exactly 22 vendored themes, got $count"
}

# bin/omamac-bg reads backgrounds.index at runtime and never hits the network
# itself to build a file list (see bg_fetch). A sync that writes colors.toml
# but skips (or empties) the index would pass every check above while leaving
# omamac-bg permanently unable to fetch wallpapers for that theme.
test_every_theme_has_a_nonempty_backgrounds_index() {
  local d idx name
  for d in "$OMAMAC_ROOT"/themes/*/; do
    name="$(basename "$d")"
    idx="${d}backgrounds.index"
    [ -f "$idx" ] || { fail "$name missing backgrounds.index"; continue; }
    [ -s "$idx" ] || fail "$name has an empty backgrounds.index"
  done
}

# The regression that motivated pinning a real release tag and reconciling
# the two colors.toml schemas in omamac_alias: every ANSI slot, cursor, and
# selection colour silently fell back to 000000 (with a warning) for every
# real vendored theme. Run the actual ghostty renderer against all 22
# vendored themes and prove none of them still does that.
#
# Grep stderr for the renderer's fallback WARNING text, not for the literal
# string '#000000' in the output — vantablack's background is legitimately
# #000000, so that string can't be used as the signal.
test_no_vendored_theme_renders_black_fallback() {
  local d name root err
  for d in "$OMAMAC_ROOT"/themes/*/; do
    name="$(basename "$d")"
    root="$TMPDIR_TEST/ghostty-${name}"
    err=$("$OMAMAC_ROOT/render/ghostty" "$d" "$root" 2>&1 >/dev/null)
    case "$err" in
      *"using 000000"*) fail "$name: ghostty renderer fell back to 000000 (${err})" ;;
    esac
  done
}

run_tests

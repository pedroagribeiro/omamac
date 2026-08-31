#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

test_writes_full_palette() {
  local root="$TMPDIR_TEST/cfg1"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local f="$root/ghostty/themes/omamac"
  assert_eq 16 "$(grep -c '^palette = ' "$f")"
  # tokyo-night's real colors.toml has no color0/color15 of its own — these
  # resolve through omamac_alias to muted and bright_foreground.
  assert_contains "$(cat "$f")" "palette = 0=#414868"
  assert_contains "$(cat "$f")" "palette = 15=#c0caf5"
}

test_writes_surface_colors() {
  local root="$TMPDIR_TEST/cfg2"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local out; out=$(cat "$root/ghostty/themes/omamac")
  assert_contains "$out" "background = #1a1b26"
  assert_contains "$out" "foreground = #a9b1d6"
  assert_contains "$out" "cursor-color = #c0caf5"
  # selection_background/selection_foreground alias to selection/foreground.
  assert_contains "$out" "selection-background = #292e42"
  assert_contains "$out" "selection-foreground = #a9b1d6"
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

test_conf_also_carries_the_theme_cursor_color() {
  local root="$TMPDIR_TEST/cfg8"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root"
  local out; out=$(cat "$root/ghostty/omamac.conf")
  # omamac.conf is a plain `config-file` include, applied LAST — later values
  # win there, unlike the `theme` include (themes/omamac), which only fills
  # in values the user hasn't set explicitly. So THIS line, not the
  # also-correct one in themes/omamac, is what actually overrides a user's
  # own explicit `cursor-color` setting (e.g. ~/.dotfiles' committed
  # `cursor-color = #ffffff`).
  assert_contains "$out" "cursor-color = #c0caf5"
}

test_is_idempotent() {
  local root="$TMPDIR_TEST/cfg5"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root" "Menlo Nerd Font"
  cp "$root/ghostty/omamac.conf" "$TMPDIR_TEST/first.conf"
  "$OMAMAC_ROOT/render/ghostty" "$THEME" "$root" "Menlo Nerd Font"
  assert_file_eq "$TMPDIR_TEST/first.conf" "$root/ghostty/omamac.conf"
}

test_missing_colors_toml_exits_1() {
  local root="$TMPDIR_TEST/cfg6" empty="$TMPDIR_TEST/empty-theme"
  mkdir -p "$empty"
  local rc; "$OMAMAC_ROOT/render/ghostty" "$empty" "$root" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme dir with no colors.toml must exit 1"
}

test_missing_colour_key_warns_and_never_emits_bare_hash() {
  local root="$TMPDIR_TEST/cfg7" partial="$TMPDIR_TEST/partial"
  mkdir -p "$partial"
  # color15 has no literal key of its own — it resolves via omamac_alias to
  # bright_foreground, so stripping THAT line is what makes it missing.
  grep -v '^bright_foreground' "$THEME/colors.toml" > "$partial/colors.toml"
  local err; err=$("$OMAMAC_ROOT/render/ghostty" "$partial" "$root" 2>&1)
  assert_contains "$err" "missing colour 'color15'"
  case "$(cat "$root/ghostty/themes/omamac")" in
    *"=#"$'\n'*|*"= #"$'\n'*) fail "emitted a bare '#' for the missing colour" ;;
  esac
  assert_contains "$(cat "$root/ghostty/themes/omamac")" "palette = 15=#000000"
}

run_tests

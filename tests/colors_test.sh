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
  # DARK is the real vendored tokyo-night colors.toml, which has no color0
  # or color15 keys of its own — these resolve through omamac_alias to
  # muted and bright_foreground respectively.
  assert_eq "414868" "$(omamac_color "$DARK" color0)"
  assert_eq "c0caf5" "$(omamac_color "$DARK" color15)"
}

test_color1_does_not_match_color15() {
  # color1 aliases to `red`, color15 aliases to `bright_foreground` — two
  # unrelated real keys. If alias resolution or the literal-key regex ever
  # blurred colorN into colorNN, this would return the wrong one.
  assert_eq "f7768e" "$(omamac_color "$DARK" color1)"
  assert_eq "c0caf5" "$(omamac_color "$DARK" color15)"
}

test_literal_key_wins_over_alias() {
  # "so any file with an explicit color4 = ... still works": a literal
  # colorN in the file must be preferred over the alias chain, and the
  # literal regex must not let color1 bleed into color15 (or vice versa).
  local f="$TMPDIR_TEST/literal.toml"
  cat > "$f" <<'EOF'
red = "#111111"
color1 = "#222222"
color15 = "#333333"
EOF
  assert_eq "222222" "$(omamac_color "$f" color1)"
  assert_eq "333333" "$(omamac_color "$f" color15)"
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

test_cursor_and_selection_keys_alias_to_real_fields() {
  # Real colors.toml has no cursor/selection_background/selection_foreground
  # keys — cursor and color15 share bright_foreground, selection_background
  # reads `selection`, selection_foreground reads `foreground`.
  assert_eq "c0caf5" "$(omamac_color "$DARK" cursor)"
  assert_eq "292e42" "$(omamac_color "$DARK" selection_background)"
  assert_eq "a9b1d6" "$(omamac_color "$DARK" selection_foreground)"
}

test_dark_theme_is_not_light_via_mode_key() {
  # tokyo-night's colors.toml has an explicit `mode = "dark"` key.
  omamac_is_light "$DARK" && fail "tokyo-night must be dark"
}

test_light_theme_is_light_via_mode_key() {
  # catppuccin-latte's colors.toml has an explicit `mode = "light"` key.
  omamac_is_light "$LIGHT" || fail "catppuccin-latte must be light"
}

test_is_light_falls_back_to_luminance_without_a_mode_key() {
  local dark_f="$TMPDIR_TEST/no-mode-dark.toml" light_f="$TMPDIR_TEST/no-mode-light.toml"
  printf 'background = "#1a1b26"\n' > "$dark_f"
  printf 'background = "#eff1f5"\n' > "$light_f"
  omamac_is_light "$dark_f" && fail "mode-less dark background must compute dark via luminance"
  omamac_is_light "$light_f" || fail "mode-less light background must compute light via luminance"
}

run_tests

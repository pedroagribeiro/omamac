#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_menu() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/gruvbox" "$OMAMAC_THEMES_DIR/nord"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/gruvbox/"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/nord/"
  cat > "$TMPDIR_TEST/fc-list" <<'EOF'
#!/usr/bin/env bash
printf 'Menlo Nerd Font\n'
EOF
  chmod +x "$TMPDIR_TEST/fc-list"
  export OMAMAC_FCLIST="$TMPDIR_TEST/fc-list"
  printf 'gruvbox\n' > "$OMAMAC_STATE/theme.name"
  mkdir -p "$OMAMAC_CACHE/backgrounds/gruvbox"
  : > "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg"
  # font/background state, so .font.current and .bg.current have something
  # to report — omamac-bg stores the full path, matching the interface's
  # documented "bg":{"current":"/abs/path.jpg",...} shape.
  printf 'Menlo Nerd Font\n' > "$OMAMAC_STATE/font"
  printf '%s\n' "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg" > "$OMAMAC_STATE/background"
}

test_output_is_valid_json() {
  setup_menu
  "$OMAMAC_BIN" menu-data | jq -e . >/dev/null || fail "menu-data is not valid JSON"
}

test_reports_current_theme_and_options() {
  setup_menu
  local out; out=$("$OMAMAC_BIN" menu-data)
  assert_eq "gruvbox" "$(printf '%s' "$out" | jq -r .theme.current)"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.theme.options | length')"
}

test_reports_fonts_and_backgrounds() {
  setup_menu
  local out; out=$("$OMAMAC_BIN" menu-data)
  assert_eq "Menlo Nerd Font" "$(printf '%s' "$out" | jq -r .font.options[0])"
  assert_eq "1-alpha.jpg" "$(printf '%s' "$out" | jq -r .bg.options[0])"
  # Assert BOTH remaining `current` fields too. Without these, swapping
  # font.current and bg.current with each other passes every other assertion.
  assert_eq "Menlo Nerd Font" "$(printf '%s' "$out" | jq -r .font.current)"
  assert_contains "$(printf '%s' "$out" | jq -r .bg.current)" "1-alpha.jpg"
}

test_emits_valid_json_when_everything_is_empty() {
  setup_tmp_home
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/no-such-themes"
  export OMAMAC_FCLIST="$TMPDIR_TEST/no-such-fclist"
  local out
  out=$("$OMAMAC_BIN" menu-data 2>/dev/null)
  printf '%s' "$out" | jq -e . >/dev/null || fail "must emit valid JSON with nothing configured"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.theme.options | length')"
  assert_eq "" "$(printf '%s' "$out" | jq -r .theme.current)"
}

test_reports_colors_from_the_current_theme() {
  setup_menu
  local out; out=$("$OMAMAC_BIN" menu-data)
  # tests/fixtures/dark/colors.toml: background=#1a1b26 foreground=#a9b1d6
  # accent=#7aa2f7 selection=#292e42 — four distinct values, so asserting
  # all four (not just background) catches a field getting swapped with
  # another rather than only checking the shape is right.
  assert_eq "#1a1b26" "$(printf '%s' "$out" | jq -r .colors.background)"
  assert_eq "#a9b1d6" "$(printf '%s' "$out" | jq -r .colors.foreground)"
  assert_eq "#7aa2f7" "$(printf '%s' "$out" | jq -r .colors.accent)"
  assert_eq "#292e42" "$(printf '%s' "$out" | jq -r .colors.selection_background)"
}

test_colors_background_is_hash_rrggbb() {
  setup_menu
  local out; out=$("$OMAMAC_BIN" menu-data)
  case "$(printf '%s' "$out" | jq -r .colors.background)" in
    '#'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "colors.background is not a lowercase #rrggbb string" ;;
  esac
}

test_names_with_quotes_do_not_break_json() {
  setup_menu
  mkdir -p "$OMAMAC_THEMES_DIR/we\"ird"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/we\"ird/"
  "$OMAMAC_BIN" menu-data | jq -e . >/dev/null || fail "quoting broke the JSON"
}

run_tests

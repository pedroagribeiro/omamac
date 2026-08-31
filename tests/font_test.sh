#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_font_env() {
  cat > "$TMPDIR_TEST/fc-list" <<'EOF'
#!/usr/bin/env bash
printf 'JetBrainsMono Nerd Font\nMenlo Nerd Font\nJetBrainsMono Nerd Font\nNoto Color Emoji\n'
EOF
  chmod +x "$TMPDIR_TEST/fc-list"
  export OMAMAC_FCLIST="$TMPDIR_TEST/fc-list"
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  # Stub the process lookup too, matching tests/theme_test.sh's setup_themes —
  # without it, `font_set`'s re-render of the active theme would query the
  # REAL process table, so the test's outcome would depend on whether the
  # developer happens to have Ghostty open.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  chmod +x "$TMPDIR_TEST/ps-none"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
}

test_list_dedupes_sorts_and_drops_emoji() {
  setup_font_env
  assert_eq "JetBrainsMono Nerd Font
Menlo Nerd Font" "$("$OMAMAC_BIN" font --list)"
}

test_set_records_current() {
  setup_font_env
  "$OMAMAC_BIN" font "Menlo Nerd Font" >/dev/null 2>&1
  assert_eq "Menlo Nerd Font" "$("$OMAMAC_BIN" font --current)"
}

test_set_rerenders_active_theme_with_new_font() {
  setup_font_env
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  "$OMAMAC_BIN" font "Menlo Nerd Font" >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf")" 'font-family = "Menlo Nerd Font"'
}

test_unavailable_font_exits_1() {
  setup_font_env
  local rc; "$OMAMAC_BIN" font "Comic Sans" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc"
}

test_set_with_no_active_theme_still_records_font() {
  setup_font_env
  # Asserting only on --current would be identical to test_set_records_current and
  # would pass whether the no-theme guard exists, is inverted, or is deleted. The
  # exit code discriminates: without the guard this shells `omamac-theme ""`,
  # which fails, so font_set returns 1 and never logs.
  local out rc
  out=$("$OMAMAC_BIN" font "Menlo Nerd Font" 2>&1); rc=$?
  assert_eq 0 "$rc" "setting a font with no active theme must succeed"
  assert_eq "Menlo Nerd Font" "$("$OMAMAC_BIN" font --current)"
  assert_contains "$out" "Font set to"
}

test_failed_rerender_reverts_font_state() {
  setup_font_env
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
  printf 'JetBrainsMono Nerd Font\n' > "$OMAMAC_STATE/font"
  rm -f "$OMAMAC_THEMES_DIR/tokyo-night/colors.toml"   # force the re-render to fail
  local rc; "$OMAMAC_BIN" font "Menlo Nerd Font" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a failed re-render must fail the font change"
  assert_eq "JetBrainsMono Nerd Font" "$("$OMAMAC_BIN" font --current)" \
    "font state must not advance past a failed render"
}

run_tests

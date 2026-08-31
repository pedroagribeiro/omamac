#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_font_env() {
  cat > "$TMPDIR_TEST/fc-list" <<'EOF'
#!/usr/bin/env bash
printf 'JetBrainsMono Nerd Font\nMenlo Nerd Font\nJetBrainsMono Nerd Font\nNoto Color Emoji\n.LastResort\n'
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

test_list_dedupes_sorts_and_drops_emoji_and_dot_families() {
  setup_font_env
  # .LastResort (and macOS's other dot-prefixed internal families, e.g.
  # .SF NS Mono, .Times LT MM) are not user-selectable — Ghostty renders every
  # glyph as a tofu box under .LastResort. They must never appear in the list.
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
  # Pins the contract that a font can be set before any theme is chosen: recorded,
  # exit 0, logged. Note it does NOT discriminate the `[ -n "$theme" ]` guard —
  # `omamac-theme ""` hits its own empty-arg case and exits 0, so removing the guard
  # changes nothing observable here. The guard stays as cheap defence (it avoids a
  # pointless subprocess, and survives omamac-theme ever rejecting an empty name),
  # but no test can prove it from outside. Do not "strengthen" this test to try.
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

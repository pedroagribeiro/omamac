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

setup_font_env_no_fclist() {
  # Like setup_font_env but deliberately leaves OMAMAC_FCLIST unset, so the
  # Ghostty tier (or the neither-available fallback) is what gets exercised.
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  chmod +x "$TMPDIR_TEST/ps-none"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
  unset OMAMAC_FCLIST
}

setup_ghostty_stub() {
  # Mirrors the real `ghostty +list-fonts` shape verified by hand: a family
  # name on an unindented line, its style names indented below it, blank
  # lines between families. `.SF NS Mono` stands in for macOS's internal
  # dot-prefixed families, which must never be offered as selectable fonts.
  cat > "$TMPDIR_TEST/ghostty" <<'EOF'
#!/usr/bin/env bash
cat <<'FONTS'
JetBrainsMono Nerd Font Mono
  JetBrainsMono NFM Bold
  JetBrainsMono NFM Regular

Menlo Nerd Font
  Menlo Nerd Font

.SF NS Mono
  .SF NS Mono Regular

Noto Color Emoji
  Noto Color Emoji Regular
FONTS
EOF
  chmod +x "$TMPDIR_TEST/ghostty"
  export OMAMAC_GHOSTTY="$TMPDIR_TEST/ghostty"
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

test_list_uses_ghostty_when_fclist_unset_and_drops_style_lines() {
  setup_font_env_no_fclist
  setup_ghostty_stub
  # The assertion that matters most here: only the two unindented family
  # names come back. If the extraction kept indented lines too, this would
  # additionally return "JetBrainsMono NFM Bold", "JetBrainsMono NFM Regular"
  # and "Menlo Nerd Font" (again, as a "style"), which are not real,
  # selectable font families — Ghostty would reject them.
  assert_eq "JetBrainsMono Nerd Font Mono
Menlo Nerd Font" "$("$OMAMAC_BIN" font --list)"
}

test_list_drops_dot_prefixed_family_from_ghostty_path() {
  setup_font_env_no_fclist
  setup_ghostty_stub
  local out; out="$("$OMAMAC_BIN" font --list)"
  case "$out" in
    *'.SF NS Mono'*) fail "dot-prefixed family '.SF NS Mono' leaked into font --list: $out" ;;
  esac
}

test_explicit_fclist_wins_over_available_ghostty() {
  setup_font_env  # exports OMAMAC_FCLIST explicitly
  setup_ghostty_stub
  # OMAMAC_FCLIST names JetBrainsMono/Menlo; the Ghostty stub above names the
  # same two families too, so this alone wouldn't distinguish the sources.
  # Make the Ghostty stub emit something fc-list would never produce, and
  # assert it's absent — proving fc-list, not Ghostty, answered the call.
  cat > "$TMPDIR_TEST/ghostty" <<'EOF'
#!/usr/bin/env bash
cat <<'FONTS'
Only From Ghostty
  Only From Ghostty Regular
FONTS
EOF
  chmod +x "$TMPDIR_TEST/ghostty"
  local out; out="$("$OMAMAC_BIN" font --list)"
  case "$out" in
    *'Only From Ghostty'*) fail "explicit OMAMAC_FCLIST was bypassed in favor of Ghostty: $out" ;;
  esac
  assert_eq "JetBrainsMono Nerd Font
Menlo Nerd Font" "$out"
}

test_list_empty_and_exits_0_when_neither_source_available() {
  setup_font_env_no_fclist
  export OMAMAC_GHOSTTY="$TMPDIR_TEST/no-such-ghostty-binary"
  # Shadow whatever `fc-list` (if any) exists on this machine's real PATH
  # with one that behaves the way a broken/absent fontconfig actually does:
  # no output, non-zero exit. Prepending (not replacing) PATH keeps bash,
  # grep, sort etc. resolvable so the rest of the script still runs.
  mkdir -p "$TMPDIR_TEST/shadow-path"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMPDIR_TEST/shadow-path/fc-list"
  chmod +x "$TMPDIR_TEST/shadow-path/fc-list"
  local out rc
  out=$(PATH="$TMPDIR_TEST/shadow-path:$PATH" "$OMAMAC_BIN" font --list 2>&1); rc=$?
  assert_eq 0 "$rc" "font --list must exit 0 when no font source is available"
  assert_eq "" "$out" "font --list must print nothing when no font source is available"
}

run_tests

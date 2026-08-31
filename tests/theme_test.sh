#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_themes() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night" "$OMAMAC_THEMES_DIR/catppuccin-latte"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$OMAMAC_THEMES_DIR/catppuccin-latte/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true"        # never signal a real process from tests
  export OMAMAC_OSASCRIPT="true"
  # Stub the process lookup too. Without this the tests read the REAL process
  # table, so which branch of ghostty_reload runs depends on whether the
  # developer happens to have Ghostty open.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  printf '#!/usr/bin/env bash\nprintf "  501 /Applications/Ghostty.app/Contents/MacOS/ghostty\\n"\n' \
    > "$TMPDIR_TEST/ps-running"
  chmod +x "$TMPDIR_TEST/ps-none" "$TMPDIR_TEST/ps-running"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
}

test_list_is_sorted() {
  setup_themes
  assert_eq "catppuccin-latte
tokyo-night" "$("$OMAMAC_BIN" theme --list)"
}

test_current_is_empty_before_any_set() {
  setup_themes
  assert_eq "" "$("$OMAMAC_BIN" theme --current)"
}

test_set_records_current() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_eq "tokyo-night" "$("$OMAMAC_BIN" theme --current)"
}

test_set_renders_ghostty() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/themes/omamac")" "background = #1a1b26"
}

test_set_applies_stored_font() {
  setup_themes
  mkdir -p "$OMAMAC_STATE"; printf 'JetBrainsMono Nerd Font\n' > "$OMAMAC_STATE/font"
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_contains "$(cat "$OMAMAC_CONFIG_ROOT/ghostty/omamac.conf")" 'font-family = "JetBrainsMono Nerd Font"'
}

test_unknown_theme_exits_1_and_leaves_current_untouched() {
  setup_themes
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  local rc; "$OMAMAC_BIN" theme no-such-theme >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc"
  assert_eq "tokyo-night" "$("$OMAMAC_BIN" theme --current)"
}

test_succeeds_when_ghostty_not_running() {
  setup_themes
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"
  local out rc
  out=$("$OMAMAC_BIN" theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc" "a theme switch must succeed with no Ghostty running"
  assert_contains "$out" "not running"
}

test_reports_reload_when_ghostty_is_running() {
  setup_themes
  export OMAMAC_PS="$TMPDIR_TEST/ps-running"
  local out rc
  out=$("$OMAMAC_BIN" theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_contains "$out" "reloaded"
}

test_switching_theme_applies_its_first_cached_wallpaper() {
  setup_themes
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg"
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_eq "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg" "$("$OMAMAC_BIN" bg --current)"
}

test_switching_theme_with_no_cached_backgrounds_does_not_fail() {
  setup_themes
  # tokyo-night here has no backgrounds.index (setup_themes only copies
  # colors.toml), so there is nothing to fetch or apply — that must be a
  # no-op, not an error.
  local rc
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "a theme with no cached/fetchable backgrounds must not fail the switch"
  assert_eq "" "$("$OMAMAC_BIN" bg --current)"
}

test_switching_theme_again_leaves_an_already_correct_wallpaper_alone() {
  setup_themes
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg"
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  "$OMAMAC_BIN" bg 2-beta.jpg >/dev/null 2>&1
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1
  assert_eq "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg" "$("$OMAMAC_BIN" bg --current)"
}

test_ghostty_render_failure_still_records_theme_name() {
  setup_themes
  # A colors.toml that resolves fine, but whose ghostty render fails for an
  # unrelated reason (an unwritable ~/.config/ghostty, a full disk, ...).
  # theme_set must still finish and record theme.name — only an unresolvable
  # theme (no colors.toml) is a hard failure now.
  local fake="$TMPDIR_TEST/fake-omamac"
  mkdir -p "$fake"
  cp -r "$OMAMAC_ROOT/bin" "$OMAMAC_ROOT/lib" "$OMAMAC_ROOT/render" "$fake/"
  cat > "$fake/render/ghostty" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fake/render/ghostty"
  local out rc
  out=$(OMAMAC_DIR="$fake" "$OMAMAC_BIN" theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc" "a ghostty render failure alone must not fail the theme switch"
  assert_contains "$out" "ghostty render failed"
  assert_eq "tokyo-night" "$(OMAMAC_DIR="$fake" "$OMAMAC_BIN" theme --current)"
}

test_missing_colors_toml_is_still_a_hard_failure_even_though_ghostty_is_now_a_warning() {
  setup_themes
  mkdir -p "$OMAMAC_THEMES_DIR/no-colors"
  local rc
  "$OMAMAC_BIN" theme no-colors >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme with no colors.toml must still hard-fail"
  assert_eq "" "$("$OMAMAC_BIN" theme --current)"
}

run_tests

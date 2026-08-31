#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

test_writes_tmtheme_with_colors() {
  local root="$TMPDIR_TEST/t1"
  export OMAMAC_BAT="true"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  local out; out=$(cat "$root/bat/themes/omamac.tmTheme")
  assert_contains "$out" "#1a1b26"
  assert_contains "$out" "<key>name</key>"
  assert_contains "$out" "omamac"
}

test_tmtheme_is_valid_plist() {
  local root="$TMPDIR_TEST/t2"
  export OMAMAC_BAT="true"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  plutil -lint "$root/bat/themes/omamac.tmTheme" >/dev/null || fail "invalid plist"
}

test_rebuilds_bat_cache() {
  local root="$TMPDIR_TEST/t3"
  cat > "$TMPDIR_TEST/bat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$BAT_LOG"
EOF
  chmod +x "$TMPDIR_TEST/bat"
  export OMAMAC_BAT="$TMPDIR_TEST/bat" BAT_LOG="$TMPDIR_TEST/bat.log"
  : > "$BAT_LOG"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  assert_contains "$(cat "$BAT_LOG")" "cache"
}

test_missing_colors_toml_exits_nonzero() {
  export OMAMAC_BAT="true"
  mkdir -p "$TMPDIR_TEST/empty"
  local rc; "$OMAMAC_ROOT/render/bat" "$TMPDIR_TEST/empty" "$TMPDIR_TEST/t4" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme dir with no colors.toml must signal failure"
}

test_missing_colour_key_warns_and_stays_valid_plist() {
  export OMAMAC_BAT="true"
  local root="$TMPDIR_TEST/t5" partial="$TMPDIR_TEST/partial-bat"
  mkdir -p "$partial"
  grep -v '^color1 ' "$THEME/colors.toml" > "$partial/colors.toml"
  local err; err=$("$OMAMAC_ROOT/render/bat" "$partial" "$root" 2>&1)
  assert_contains "$err" "missing colour 'color1'"
  # A bare "#" is still valid XML, so lint alone cannot catch it — assert the
  # fallback landed, then confirm the document is still well-formed.
  assert_contains "$(cat "$root/bat/themes/omamac.tmTheme")" "#000000"
  plutil -lint "$root/bat/themes/omamac.tmTheme" >/dev/null || fail "invalid plist"
}

run_tests

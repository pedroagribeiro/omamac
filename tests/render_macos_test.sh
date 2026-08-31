#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

stub_osascript() {
  cat > "$TMPDIR_TEST/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OSA_LOG"
EOF
  chmod +x "$TMPDIR_TEST/osascript"
  export OMAMAC_OSASCRIPT="$TMPDIR_TEST/osascript"
  export OSA_LOG="$TMPDIR_TEST/osa.log"
  : > "$OSA_LOG"
}

test_dark_theme_sets_dark_mode_true() {
  stub_osascript
  "$OMAMAC_ROOT/render/macos" "$OMAMAC_ROOT/tests/fixtures/dark"
  assert_contains "$(cat "$OSA_LOG")" "set dark mode to true"
}

test_light_theme_sets_dark_mode_false() {
  stub_osascript
  "$OMAMAC_ROOT/render/macos" "$OMAMAC_ROOT/tests/fixtures/light"
  assert_contains "$(cat "$OSA_LOG")" "set dark mode to false"
}

run_tests

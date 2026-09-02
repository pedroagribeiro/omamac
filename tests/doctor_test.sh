#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A machine where everything omamac writes is present, current, and actually
# wired up. Each test below breaks exactly ONE thing and asserts that the
# matching check — not merely "some check" — reports it. A doctor that only
# ever says ok is worse than no doctor, so every check has to be shown to
# discriminate.
setup_healthy() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night" "$OMAMAC_THEMES_DIR/catppuccin-latte"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml"  "$OMAMAC_THEMES_DIR/tokyo-night/"
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$OMAMAC_THEMES_DIR/catppuccin-latte/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_CLAUDE_DIR="$TMPDIR_TEST/claude"
  export OMAMAC_KILL="true"
  # An osascript that reports whatever was last set — doctor now asks macOS
  # what it is actually showing, so "true" is no longer a sufficient stub.
  cat > "$TMPDIR_TEST/osascript" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"set picture to"*)
    printf '%s' "$*" | sed 's/.*set picture to "//; s/".*//' > "$OSA_STORE" ;;
  *"get picture of every desktop"*)
    [ -f "$OSA_STORE" ] || exit 0
    v=$(cat "$OSA_STORE"); printf '%s, %s\n' "$v" "$v" ;;
esac
EOF
  chmod +x "$TMPDIR_TEST/osascript"
  export OMAMAC_OSASCRIPT="$TMPDIR_TEST/osascript" OSA_STORE="$TMPDIR_TEST/osa.store"
  export OMAMAC_DESKTOP_INTERVAL=0
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMPDIR_TEST/ps-none"
  chmod +x "$TMPDIR_TEST/ps-none"
  export OMAMAC_PS="$TMPDIR_TEST/ps-none"

  # Isolate git completely: doctor resolves delta.* through the real config
  # chain, which is the point of that check, so the chain must be the test's.
  export GIT_CONFIG_GLOBAL="$TMPDIR_TEST/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null

  # Generate every renderer's output for real.
  "$OMAMAC_BIN" theme tokyo-night >/dev/null 2>&1

  BG=$(sed -n -E 's/^[[:space:]]*background[[:space:]]*=[[:space:]]*"?#?([0-9A-Fa-f]{6})"?.*/\1/p' \
    "$OMAMAC_THEMES_DIR/tokyo-night/colors.toml" | head -1)

  # ...then the pointers, which are the user's side of the contract.
  printf 'font-family = "Menlo"\nconfig-file = ?omamac.conf\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/btop"
  printf 'color_theme = "omamac"\n' > "$OMAMAC_CONFIG_ROOT/btop/btop.conf"
  mkdir -p "$OMAMAC_CLAUDE_DIR"
  printf '{ "theme": "custom:omamac" }\n' > "$OMAMAC_CLAUDE_DIR/settings.json"
  printf '[include]\n\tpath = %s/git/omamac.ini\n' "$OMAMAC_CONFIG_ROOT" > "$GIT_CONFIG_GLOBAL"

  # bat compiles themes into a cache, so ask bat itself rather than the file.
  printf '#!/usr/bin/env bash\nprintf "Monokai Extended\\nomamac\\n"\n' > "$TMPDIR_TEST/bat-ok"
  printf '#!/usr/bin/env bash\nprintf "Monokai Extended\\n"\n'          > "$TMPDIR_TEST/bat-nocache"
  chmod +x "$TMPDIR_TEST/bat-ok" "$TMPDIR_TEST/bat-nocache"
  export OMAMAC_BAT="$TMPDIR_TEST/bat-ok"

  printf '#!/usr/bin/env bash\nprintf "Dark\\n"\n'  > "$TMPDIR_TEST/defaults-dark"
  printf '#!/usr/bin/env bash\nexit 1\n'            > "$TMPDIR_TEST/defaults-light"
  chmod +x "$TMPDIR_TEST/defaults-dark" "$TMPDIR_TEST/defaults-light"
  export OMAMAC_DEFAULTS="$TMPDIR_TEST/defaults-dark"

  printf 'wallpaper\n' > "$TMPDIR_TEST/wall.jpg"
  printf '%s\n' "$TMPDIR_TEST/wall.jpg" > "$OMAMAC_STATE/background"
  printf '%s' "$TMPDIR_TEST/wall.jpg" > "$OSA_STORE"   # macOS is showing it
}

doctor() { "$OMAMAC_BIN" doctor 2>&1; }

# Asserts doctor failed AND that the failing line is the one expected.
assert_flags() {
  local pattern="$1" out rc
  out=$(doctor); rc=$?
  assert_eq 1 "$rc" "doctor must exit non-zero when a check fails"
  printf '%s\n' "$out" | grep -q "FAIL.*$pattern" \
    || fail "expected a FAIL matching '$pattern'; got:\n$out"
}

test_a_healthy_machine_passes_everything() {
  setup_healthy
  local out rc
  out=$(doctor); rc=$?
  assert_eq 0 "$rc" "a healthy machine must exit 0; got:\n$out"
  case "$out" in *FAIL*) fail "unexpected FAIL on a healthy machine:\n$out" ;; esac
  assert_contains "$out" "All checks passed."
}

# The failure that makes everything else meaningless: files generated
# correctly, and the terminal never told to read them.
test_detects_a_ghostty_config_that_never_includes_omamac() {
  setup_healthy
  printf 'font-family = "Menlo"\n' > "$OMAMAC_CONFIG_ROOT/ghostty/config"
  assert_flags "ghostty.*no 'config-file"
}

test_detects_a_stale_ghostty_palette() {
  setup_healthy
  printf 'background = #000000\n' > "$OMAMAC_CONFIG_ROOT/ghostty/themes/omamac"
  assert_flags "ghostty.*stale"
}

test_detects_a_stale_nvim_colorscheme() {
  setup_healthy
  printf -- '-- stale\n' > "$OMAMAC_STATE/current/omamac.lua"
  assert_flags "nvim.*stale"
}

test_detects_btop_not_selecting_the_theme() {
  setup_healthy
  printf 'color_theme = "Default"\n' > "$OMAMAC_CONFIG_ROOT/btop/btop.conf"
  assert_flags "btop.*does not select"
}

# The file can be perfect and still invisible: bat only sees themes it has
# compiled into its cache.
test_detects_a_bat_theme_that_bat_cannot_see() {
  setup_healthy
  export OMAMAC_BAT="$TMPDIR_TEST/bat-nocache"
  assert_flags "bat.*bat cache --build"
}

test_detects_a_delta_include_that_is_not_wired_in() {
  setup_healthy
  : > "$GIT_CONFIG_GLOBAL"
  assert_flags "delta.*include.*missing or ordered"
}

# The exact bug that motivated render/delta: a hardcoded light setting that
# contradicts the theme.
test_detects_delta_light_contradicting_the_theme() {
  setup_healthy
  printf '[include]\n\tpath = %s/git/omamac.ini\n[delta]\n\tlight = true\n' \
    "$OMAMAC_CONFIG_ROOT" > "$GIT_CONFIG_GLOBAL"
  assert_flags "delta.*light = 'true'.*is dark"
}

test_detects_claude_settings_not_selecting_the_theme() {
  setup_healthy
  printf '{ "theme": "dark" }\n' > "$OMAMAC_CLAUDE_DIR/settings.json"
  assert_flags "claude.*does not set"
}

test_detects_stale_claude_colours() {
  setup_healthy
  printf '{"name":"omamac","base":"dark","overrides":{"inverseText":"#000000"}}\n' \
    > "$OMAMAC_CLAUDE_DIR/themes/omamac.json"
  assert_flags "claude.*stale"
}

test_detects_a_corrupt_claude_theme() {
  setup_healthy
  printf '{ not json\n' > "$OMAMAC_CLAUDE_DIR/themes/omamac.json"
  assert_flags "claude.*not valid JSON"
}

test_detects_system_appearance_out_of_step_with_the_theme() {
  setup_healthy
  export OMAMAC_DEFAULTS="$TMPDIR_TEST/defaults-light"   # reports light
  assert_flags "macos.*light but.*is dark"
}

test_detects_a_wallpaper_that_no_longer_exists() {
  setup_healthy
  rm -f "$TMPDIR_TEST/wall.jpg"
  assert_flags "bg.*wallpaper is gone"
}

# Both shapes this project has actually produced in its own cache.
test_detects_a_zero_byte_cache_entry() {
  setup_healthy
  mkdir -p "$OMAMAC_CACHE/thumbs"
  : > "$OMAMAC_CACHE/thumbs/poisoned.jpg"
  assert_flags "cache.*zero-byte"
}

test_detects_an_interrupted_download() {
  setup_healthy
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  printf 'partial' > "$OMAMAC_CACHE/backgrounds/tokyo-night/.half.jpg.part"
  assert_flags "cache.*leftover .part"
}

test_no_theme_applied_is_a_clear_error_not_a_wall_of_failures() {
  setup_healthy
  rm -f "$OMAMAC_STATE/theme.name"
  local out rc
  out=$(doctor); rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no theme has been applied yet"
  case "$out" in *FAIL*) fail "an unconfigured machine must not emit a wall of FAILs:\n$out" ;; esac
}

# Read-only by design: drift is the finding, and a diagnostic that repairs what
# it inspects can never tell you something was wrong.
test_doctor_changes_nothing() {
  setup_healthy
  local before after
  before=$(find "$OMAMAC_CONFIG_ROOT" "$OMAMAC_STATE" "$OMAMAC_CLAUDE_DIR" -type f -exec shasum {} \; 2>/dev/null | sort)
  doctor >/dev/null
  after=$(find "$OMAMAC_CONFIG_ROOT" "$OMAMAC_STATE" "$OMAMAC_CLAUDE_DIR" -type f -exec shasum {} \; 2>/dev/null | sort)
  assert_eq "$before" "$after" "doctor must not modify anything it inspects"
}


# The check that would have caught the bug this all came from. The recorded
# file existed and was perfectly valid; macOS was simply showing a previous
# theme's wallpaper instead, and the old "does the file exist" check passed.
test_detects_a_wallpaper_macos_is_not_actually_showing() {
  setup_healthy
  printf '%s' "/somewhere/else.jpg" > "$OSA_STORE"
  assert_flags "bg.*showing a different wallpaper"
}

run_tests

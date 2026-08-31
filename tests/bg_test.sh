#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_bg() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true"
  cat > "$TMPDIR_TEST/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OSA_LOG"
EOF
  chmod +x "$TMPDIR_TEST/osascript"
  export OMAMAC_OSASCRIPT="$TMPDIR_TEST/osascript" OSA_LOG="$TMPDIR_TEST/osa.log"
  : > "$OSA_LOG"
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg"
  omamac_state_set() { :; }
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

test_list_returns_cached_basenames_sorted() {
  setup_bg
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
}

test_set_records_absolute_path_and_calls_osascript() {
  setup_bg
  "$OMAMAC_BIN" bg 2-beta.jpg >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "2-beta.jpg"
  assert_contains "$(cat "$OSA_LOG")" "set picture to"
}

test_next_cycles_and_wraps() {
  setup_bg
  "$OMAMAC_BIN" bg 1-alpha.jpg >/dev/null 2>&1
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "2-beta.jpg"
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "1-alpha.jpg"
}

test_next_with_nothing_set_picks_the_first() {
  setup_bg
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "1-alpha.jpg"
}

test_unknown_wallpaper_exits_1() {
  setup_bg
  local rc; "$OMAMAC_BIN" bg nope.jpg >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc"
}

# --- Step 5: on-demand fetch, exercised with no network ---
#
# The brief's Step 5 sample lists a theme's upstream backgrounds via the GitHub
# contents API (a hardcoded https://api.github.com URL), which cannot be pointed
# at a file:// fixture tree. Per the task's own instructions, that path was made
# testable instead: the listing step also goes through OMAMAC_OMARCHY_RAW (via an
# "index" manifest file alongside the backgrounds) and through OMAMAC_FETCH, so
# both the listing and the download legs are exercised end-to-end against a local
# file:// fixture tree with the real (unstubbed) curl — no network, no stubbing.
setup_bg_fetch() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/omarchy"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

test_list_fetches_upstream_when_cache_is_empty() {
  setup_bg_fetch
  # Cache starts empty: nothing under $OMAMAC_CACHE/backgrounds/tokyo-night yet.
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
  assert_eq "hello-alpha" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg")"
  assert_eq "hello-beta" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg")"
}

test_list_does_not_refetch_a_populated_cache() {
  setup_bg_fetch
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  printf 'already-here' > "$OMAMAC_CACHE/backgrounds/tokyo-night/only.jpg"
  assert_eq "only.jpg" "$("$OMAMAC_BIN" bg --list)"
  assert_eq "already-here" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/only.jpg")"
}

run_tests

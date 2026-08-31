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
# contents API (a hardcoded https://api.github.com URL). That call cannot be
# pointed at a fixture for tests and is rate-limited at runtime — and it turns
# out upstream ships no such index of its own anyway. So the file list is
# vendored instead: tools/sync-themes (Task 12) writes a plain-text
# backgrounds.index into each theme's directory at vendor time, when it already
# has GitHub API access. bg_fetch reads that local index — no network — and
# only the per-file downloads go over OMAMAC_FETCH, against a pinned upstream
# revision. In tests, OMAMAC_OMARCHY_RAW/OMAMAC_OMARCHY_REV point at a local
# file:// fixture tree, so even the download leg never touches the network;
# curl itself is never stubbed, it just never leaves the filesystem.
setup_bg_fetch() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  printf '1-alpha.jpg\n2-beta.jpg\n' > "$OMAMAC_THEMES_DIR/tokyo-night/backgrounds.index"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/omarchy"
  export OMAMAC_OMARCHY_REV="rev"
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

test_list_with_no_backgrounds_index_warns_and_succeeds() {
  setup_bg_fetch
  rm -f "$OMAMAC_THEMES_DIR/tokyo-night/backgrounds.index"
  local out rc
  out=$("$OMAMAC_BIN" bg --list 2>&1); rc=$?
  assert_eq 0 "$rc" "a missing backgrounds.index must not fail the command"
  assert_eq "" "$("$OMAMAC_BIN" bg --list 2>/dev/null)"
  assert_contains "$out" "no backgrounds.index"
}

run_tests

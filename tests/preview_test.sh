#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A stub sips that "converts" by copying its input (the arg right before
# --out) to the --out path. Parses --out out of the argument list rather
# than assuming a fixed position.
setup_sips_ok() {
  cat > "$TMPDIR_TEST/sips-ok" <<'EOF'
#!/usr/bin/env bash
src=""
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then
    out="$a"
  fi
  prev="$a"
done
# The source path is the argument immediately before --out.
prev=""
for a in "$@"; do
  if [ "$a" = "--out" ]; then
    src="$prev"
  fi
  prev="$a"
done
cp "$src" "$out"
EOF
  chmod +x "$TMPDIR_TEST/sips-ok"
  export OMAMAC_SIPS="$TMPDIR_TEST/sips-ok"
}

# A stub sips that reproduces the real tool's failure mode: it creates the
# --out file (a zero-byte stub) and THEN fails, exit 1.
setup_sips_fails_after_creating_out() {
  cat > "$TMPDIR_TEST/sips-fail" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then
    out="$a"
  fi
  prev="$a"
done
: > "$out"
exit 1
EOF
  chmod +x "$TMPDIR_TEST/sips-fail"
  export OMAMAC_SIPS="$TMPDIR_TEST/sips-fail"
}

setup_preview_env() {
  printf 'gruvbox\n' > "$OMAMAC_STATE/theme.name"
  mkdir -p "$OMAMAC_CACHE/backgrounds/gruvbox"
  printf 'fake-jpeg-bytes\n' > "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg"
}

test_no_arguments_exits_cleanly() {
  setup_preview_env
  local out rc
  out=$("$OMAMAC_BIN" preview 2>&1); rc=$?
  assert_eq 0 "$rc" "no-args call must exit 0, not crash"
  assert_eq "" "$out"
}

test_unknown_basename_exits_cleanly() {
  setup_preview_env
  local out rc
  out=$("$OMAMAC_BIN" preview does-not-exist.jpg 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

test_no_current_theme_exits_cleanly() {
  # No theme.name written at all.
  mkdir -p "$OMAMAC_CACHE/backgrounds/gruvbox"
  printf 'fake-jpeg-bytes\n' > "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg"
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

test_successful_conversion_emits_data_uri_and_caches_thumb() {
  setup_preview_env
  setup_sips_ok
  local out
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg)
  assert_contains "$out" "data:image/jpeg;base64,"
  [ -s "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.jpg" ] || fail "thumbnail was not cached"
}

test_failed_conversion_does_not_poison_the_cache() {
  setup_preview_env
  setup_sips_fails_after_creating_out
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed conversion must still exit 0 (quiet degradation)"
  assert_eq "" "$out" "a failed conversion must produce no output, not a malformed data URI"
  [ -f "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.jpg" ] && \
    fail "a failed conversion must not leave a stub thumbnail behind"

  # And recovery: a subsequent call with a working sips must succeed rather
  # than being permanently served the poisoned (zero-byte) cache entry. A
  # merely-present "data:image/jpeg;base64," prefix isn't enough to prove
  # this — base64 of the empty poisoned stub also yields that prefix with
  # nothing after it — so require an actual non-empty payload.
  setup_sips_ok
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg)
  assert_contains "$out" "data:image/jpeg;base64,"
  local payload="${out#data:image/jpeg;base64,}"
  [ -n "$payload" ] || fail "recovery must serve a real thumbnail, not the poisoned empty stub"
}

# ---------------------------------------------------------------------------
# Theme previews (`omamac preview --theme <name>`).
#
# Omarchy's theme switcher is the SAME image picker as its background
# switcher — bin/omarchy-theme-switcher shells out to omarchy-menu-images with
# --print-name --show-labels --filterable — fed from a directory of one
# preview image per theme. omarchy-theme-switcher's find_preview() prefers
# themes/<name>/preview.{png,jpg,...} and only falls back to the theme's first
# background; at v4.0.2 all 22 stock themes ship a preview.png, so that is the
# single source omamac fetches.
#
# Unlike wallpapers, these are for a theme that is NOT the current one (that is
# the entire point of the picker), so this path cannot read theme.name — the
# name arrives from the menu page. It is therefore validated against the
# VENDORED theme list before being interpolated into a URL or a cache path.
# ---------------------------------------------------------------------------

setup_theme_preview_env() {
  # Same reset discipline as bg_test.sh: run_tests shares one shell across
  # tests, so an export from a neighbouring test must not decide this one.
  unset OMAMAC_FETCH
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  # A file:// fixture tree, so the download leg never touches the network and
  # curl itself is never stubbed — it just never leaves the filesystem.
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/omarchy"
  export OMAMAC_OMARCHY_REV="rev"
}

test_theme_preview_fetches_caches_and_emits_a_data_uri() {
  setup_theme_preview_env
  setup_sips_ok
  local out
  out=$("$OMAMAC_BIN" preview --theme tokyo-night)
  assert_contains "$out" "data:image/jpeg;base64,"
  local payload="${out#data:image/jpeg;base64,}"
  [ -n "$payload" ] || fail "theme preview must carry a real payload, not an empty base64 body"
  assert_eq "fake-png-bytes" "$(cat "$OMAMAC_CACHE/theme-previews/tokyo-night.png")" \
    "the upstream preview.png must be cached under its own name"
  [ -s "$OMAMAC_CACHE/theme-thumbs/tokyo-night.jpg" ] || fail "theme thumbnail was not cached"
}

test_theme_preview_does_not_refetch_an_already_cached_source() {
  setup_theme_preview_env
  setup_sips_ok
  mkdir -p "$OMAMAC_CACHE/theme-previews"
  # Content that differs from the fixture's: if the source were re-fetched
  # anyway this would be clobbered with "fake-png-bytes".
  printf 'already-here' > "$OMAMAC_CACHE/theme-previews/tokyo-night.png"
  "$OMAMAC_BIN" preview --theme tokyo-night >/dev/null
  assert_eq "already-here" "$(cat "$OMAMAC_CACHE/theme-previews/tokyo-night.png")" \
    "a cached preview source must not be re-downloaded on every menu open"
}

# The fixture tree deliberately carries a themes/unvendored/preview.png that
# $OMAMAC_THEMES_DIR does NOT vendor, so the download would genuinely SUCCEED
# if the guard were dropped. A name that simply 404s upstream cannot prove
# anything here: that path produces no output and no cache entry with or
# without the guard, so the test would stay green against the mutant.
test_theme_preview_rejects_a_theme_omamac_does_not_vendor() {
  setup_theme_preview_env
  setup_sips_ok
  local out rc
  out=$("$OMAMAC_BIN" preview --theme unvendored 2>&1); rc=$?
  assert_eq 0 "$rc" "an unknown theme must degrade quietly, like every other preview failure"
  assert_eq "" "$out" "a theme omamac does not vendor must produce nothing, even though upstream has one"
  [ -e "$OMAMAC_CACHE/theme-previews/unvendored.png" ] && \
    fail "an unknown theme must not be fetched at all"
}

# The theme name reaches this command from the MENU PAGE, so it is the one
# preview input that is not a filename omamac itself produced. It is
# interpolated into both an upstream URL and a cache path, so a name
# containing ../ must never be acted on. The vendored-theme check above is
# what enforces that; this pins the traversal case specifically, since
# "does the directory exist" and "is this a safe path component" are not the
# same question and a future relaxation of the former would silently lose
# the latter.
# Every leg of this is arranged to SUCCEED if the guard is removed, so the
# test dies with it: ../evil resolves to a real colors.toml next to
# $OMAMAC_THEMES_DIR (defeating the vendored-theme check on its own), and the
# fixture tree carries rev/evil/preview.png so the URL
# .../rev/themes/../evil/preview.png genuinely resolves and downloads.
test_theme_preview_rejects_a_path_traversal_name() {
  setup_theme_preview_env
  setup_sips_ok
  mkdir -p "$TMPDIR_TEST/evil"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$TMPDIR_TEST/evil/"
  local out rc
  out=$("$OMAMAC_BIN" preview --theme "../evil" 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out" "a traversing theme name must produce nothing, even when every path it names resolves"
  [ -e "$OMAMAC_CACHE/evil.png" ] && \
    fail "a traversing theme name must never write outside the theme-previews cache"
}

test_theme_preview_with_no_name_exits_cleanly() {
  setup_theme_preview_env
  setup_sips_ok
  local out rc
  out=$("$OMAMAC_BIN" preview --theme 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

test_theme_preview_failed_download_leaves_no_stub_and_emits_nothing() {
  setup_theme_preview_env
  setup_sips_ok
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/does-not-exist"
  local out rc
  out=$("$OMAMAC_BIN" preview --theme tokyo-night 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed download must still exit 0 (quiet degradation)"
  assert_eq "" "$out"
  local stray; stray=$(find "$OMAMAC_CACHE/theme-previews" -maxdepth 1 -type f 2>/dev/null)
  assert_eq "" "$stray" "a failed download must leave nothing behind — not the file, not a .part"
}

run_tests

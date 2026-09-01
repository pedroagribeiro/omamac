#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Stub sips shared by the tests below. The real tool is asked two different
# questions by omamac-preview — "what size is this image" and "convert it" —
# so the stub has to answer both: -g reports STUB_W/STUB_H in the real tool's
# output shape, and anything else is a conversion, whose full argv is recorded
# so a test can assert the RECIPE (Omarchy's 1536x864 @ Q82) and not merely
# that some conversion happened.
write_sips_stub() {
  local path="$1" mode="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-g" ]; then
  for a in "\$@"; do
    case "\$a" in
      pixelWidth)  printf '  pixelWidth: %s\n'  "\${STUB_W:-1800}" ;;
      pixelHeight) printf '  pixelHeight: %s\n' "\${STUB_H:-1012}" ;;
    esac
  done
  exit 0
fi
printf '%s\n' "\$*" >> "\$SIPS_ARGV_LOG"
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--out" ]; then out="\$a"; fi
  prev="\$a"
done
# The source path is the argument immediately before --out.
src=""
prev=""
for a in "\$@"; do
  if [ "\$a" = "--out" ]; then src="\$prev"; fi
  prev="\$a"
done
if [ "$mode" = "fail" ]; then
  # Reproduces the real tool's failure mode: it creates the --out file (a
  # zero-byte stub) and THEN fails.
  : > "\$out"
  exit 1
fi
cp "\$src" "\$out"
EOF
  chmod +x "$path"
  export OMAMAC_SIPS="$path"
  export SIPS_ARGV_LOG="$TMPDIR_TEST/sips.argv"
  : > "$SIPS_ARGV_LOG"
}

setup_sips_ok() { write_sips_stub "$TMPDIR_TEST/sips-ok" ok; }

# A stub sips that reproduces the real tool's failure mode: it creates the
# --out file and THEN fails, exit 1.
setup_sips_fails_after_creating_out() { write_sips_stub "$TMPDIR_TEST/sips-fail" fail; }

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
  [ -s "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.1536x864q82.jpg" ] || fail "thumbnail was not cached"
}

test_failed_conversion_does_not_poison_the_cache() {
  setup_preview_env
  setup_sips_fails_after_creating_out
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed conversion must still exit 0 (quiet degradation)"
  assert_eq "" "$out" "a failed conversion must produce no output, not a malformed data URI"
  [ -f "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.1536x864q82.jpg" ] && \
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
  [ -s "$OMAMAC_CACHE/theme-thumbs/tokyo-night.1536x864q82.jpg" ] || fail "theme thumbnail was not cached"
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

# ---------------------------------------------------------------------------
# The thumbnail recipe, pinned to Omarchy's.
#
# bin/omarchy-menu-images' generate_thumbnail is ONE code path for both
# pickers:
#
#   vipsthumbnail <src> --size 1536x864 --smartcrop=centre \
#                       --path <out>[Q=82,strip]
#
# 1536x864 is exactly twice the 768x432 the coverflow paints, so on a Retina
# panel the expanded item lands 1:1 on the backing store. Anything smaller is
# upscaled into that space, and a theme preview is a desktop screenshot full
# of 10px text, where that is immediately visible.
# ---------------------------------------------------------------------------

# Pulls the recorded conversion argv (the -g size query is not logged).
sips_conversion_argv() { cat "$SIPS_ARGV_LOG" 2>/dev/null; }

test_thumbnails_use_omarchys_size_crop_and_quality() {
  setup_theme_preview_env
  setup_sips_ok
  # A 16:9-ish source, the shape every stock theme preview.png actually is.
  export STUB_W=1800 STUB_H=1012
  "$OMAMAC_BIN" preview --theme tokyo-night >/dev/null
  local argv; argv=$(sips_conversion_argv)
  [ -n "$argv" ] || { fail "no conversion was attempted at all"; return; }
  assert_contains "$argv" "-s formatOptions 82" "Q=82, as upstream passes to vips"
  # --smartcrop=centre is two operations: scale so the image COVERS the box,
  # then centre-crop to exactly it. 1800x1012 covers 1536x864 at scale
  # 864/1012, i.e. 1537x864 — so the crop is what trims the last pixel of
  # width. sips takes HEIGHT then WIDTH for both -z and -c.
  assert_contains "$argv" "-z 864 1537" "must cover-scale, preserving aspect, before cropping"
  assert_contains "$argv" "-c 864 1536" "must centre-crop to exactly 1536x864"
}

# The cover-scale is the half that a plain `sips -Z 1536` would get wrong, and
# it only shows up on a source that is NOT already 16:9 — which is every
# wallpaper. 6016x3384 is 1.778:1... no: it is 1.7778 vs the box's 1.7778,
# so this uses a deliberately different aspect to make the crop bite.
test_thumbnail_cover_scale_crops_rather_than_letterboxes() {
  setup_preview_env
  setup_sips_ok
  # 4:3 source: covering a 16:9 box means matching the WIDTH and cropping
  # height. A fit-inside (-Z) would instead match the height and leave the
  # image 1152 wide, framing something quite different.
  export STUB_W=4096 STUB_H=3072
  "$OMAMAC_BIN" preview 1-alpha.jpg >/dev/null
  local argv; argv=$(sips_conversion_argv)
  [ -n "$argv" ] || { fail "no conversion was attempted at all"; return; }
  assert_contains "$argv" "-z 1152 1536" "a 4:3 source must be scaled to cover the box on WIDTH (1536x1152)"
  assert_contains "$argv" "-c 864 1536" "and then centre-cropped down to 1536x864"
}

test_unreadable_source_dimensions_degrade_quietly() {
  setup_preview_env
  setup_sips_ok
  # sips answering with no usable size means it cannot read the file as an
  # image at all, so the conversion would fail too. Bail rather than guess a
  # size and emit a malformed thumbnail.
  export STUB_W=0 STUB_H=0
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
  assert_eq "" "$(sips_conversion_argv)" "no conversion must be attempted when the source size is unknown"
}

# A thumbnail cached under a DIFFERENT recipe must not be served. The
# staleness check is "is the source newer than the thumbnail", which cannot
# see a change on omamac's side at all — so when the recipe moved from 1024
# to Omarchy's 1536x864, every machine that had already opened a picker would
# have kept serving the old soft thumbnails forever, and the change would
# have looked like it did nothing.
test_a_thumbnail_from_another_recipe_is_not_served() {
  setup_preview_env
  setup_sips_ok
  mkdir -p "$OMAMAC_CACHE/thumbs/gruvbox"
  # What the previous recipe would have left behind, newer than the source.
  printf 'stale-1024-thumb' > "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.jpg"
  "$OMAMAC_BIN" preview 1-alpha.jpg >/dev/null
  [ -s "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.1536x864q82.jpg" ] || \
    fail "the current recipe must produce its own cache entry, not reuse another one"
  local argv; argv=$(sips_conversion_argv)
  assert_contains "$argv" "-c 864 1536" "a thumbnail from another recipe must trigger a real re-render"
}

# --paths is the only mode the Hammerspoon host uses, because the host gets
# exactly ONE hs.task per picker level: measured against the real thing, 22
# concurrent hs.tasks — each a trivial bash run that exited 0 with no stderr —
# delivered ZERO bytes of stdout to their callbacks for 15 to 19 of them,
# varying run to run. It emits paths rather than bytes for a second reason:
# even a single task truncated a ~430KB data URI, every truncation landing on
# an exact multiple of 1024 bytes, because the completion callback can fire
# before the last streamed chunk arrives. The host reads these files itself.

# A wallpaper level whose listing cannot wander onto the network: gruvbox is
# vendored for real, so without an override `bg --list` would fetch its actual
# backgrounds from GitHub during the test.
setup_offline_wallpaper_level() {
  setup_preview_env
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/gruvbox"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/gruvbox/"
  # No backgrounds.index, so bg_fetch warns and returns without downloading;
  # bg_list then simply lists what is already cached.
}

test_paths_mode_lists_every_theme_with_a_real_thumbnail() {
  setup_theme_preview_env
  setup_sips_ok
  local out; out=$("$OMAMAC_BIN" preview --paths --theme 2>/dev/null)
  # Only tokyo-night is vendored in this fixture.
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "one line per theme in the level"
  local name path
  name=$(printf '%s' "$out" | cut -f1)
  path=$(printf '%s' "$out" | cut -f2)
  assert_eq "tokyo-night" "$name"
  assert_eq "$OMAMAC_CACHE/theme-thumbs/tokyo-night.1536x864q82.jpg" "$path"
  [ -s "$path" ] || fail "--paths must BUILD each thumbnail, not merely name where it would go"
  # And it must be the very same file the single-item data-URI form encodes,
  # or the host would be handed a path to something no other mode refreshes.
  assert_eq "data:image/jpeg;base64,$(base64 -i "$path" | tr -d '\n')" \
    "$("$OMAMAC_BIN" preview --theme tokyo-night)" \
    "the data-URI mode must encode exactly the file --paths names"
}

test_paths_mode_lists_wallpapers_when_no_theme_flag_is_given() {
  setup_offline_wallpaper_level
  setup_sips_ok
  local out; out=$("$OMAMAC_BIN" preview --paths 2>/dev/null)
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)"
  assert_eq "1-alpha.jpg" "$(printf '%s' "$out" | cut -f1)"
  assert_eq "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.1536x864q82.jpg" "$(printf '%s' "$out" | cut -f2)"
  [ -s "$(printf '%s' "$out" | cut -f2)" ] || fail "--paths must build the wallpaper thumbnail"
}

test_paths_mode_never_emits_image_bytes() {
  setup_theme_preview_env
  setup_sips_ok
  local out; out=$("$OMAMAC_BIN" preview --paths --theme 2>/dev/null)
  case "$out" in
    *data:image*) fail "--paths must print paths, not bytes — the whole point is keeping them out of the pipe" ;;
  esac
}

test_paths_mode_omits_items_it_cannot_build_rather_than_naming_them() {
  setup_theme_preview_env
  setup_sips_ok
  # A second vendored theme that upstream has no preview.png for, so its fetch
  # fails. A line naming a file that does not exist would make the host log an
  # unreadable-thumbnail error for something that was never going to work.
  mkdir -p "$OMAMAC_THEMES_DIR/ghost-theme"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/ghost-theme/"
  local out; out=$("$OMAMAC_BIN" preview --paths --theme 2>/dev/null)
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "only the theme that produced a thumbnail may be listed"
  assert_eq "tokyo-night" "$(printf '%s' "$out" | cut -f1)"
  case "$out" in
    *ghost-theme*) fail "a theme whose preview could not be fetched must be omitted, not named" ;;
  esac
}

test_paths_mode_with_nothing_to_list_is_silent_and_succeeds() {
  setup_theme_preview_env
  setup_sips_ok
  rm -rf "$OMAMAC_THEMES_DIR"
  mkdir -p "$OMAMAC_THEMES_DIR"
  local out rc
  out=$("$OMAMAC_BIN" preview --paths --theme 2>/dev/null); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

run_tests

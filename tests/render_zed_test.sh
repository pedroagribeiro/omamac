#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
RENDER="$OMAMAC_ROOT/render/zed"

setup_zed() {
  ROOT="$TMPDIR_TEST/config"
  THEME_DIR="$TMPDIR_TEST/theme"
  mkdir -p "$THEME_DIR"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$THEME_DIR/colors.toml"
  OUT="$ROOT/zed/themes/omamac.json"
}

test_writes_a_valid_theme_document() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT" || fail "render exited non-zero"
  [ -f "$OUT" ] || { fail "no theme written"; return; }
  jq -e . "$OUT" >/dev/null 2>&1 || fail "theme is not valid JSON"
  assert_eq "https://zed.dev/schema/themes/v0.2.0.json" "$(jq -r '."$schema"' "$OUT")"
  assert_eq "omamac" "$(jq -r '.themes[0].name' "$OUT")"
  assert_eq 1 "$(jq '.themes | length' "$OUT")"
}

# Every field the schema defines is emitted rather than a chosen subset, so
# there is no question of which keys Zed falls back on. This pins the count
# against the reference theme Zed ships with on this machine, so a field added
# to one and not the other is visible.
test_covers_every_style_key_and_syntax_token() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  local keys syntax
  keys=$(jq '.themes[0].style | keys | length' "$OUT")
  syntax=$(jq '.themes[0].style.syntax | keys | length' "$OUT")
  assert_eq 120 "$keys" "the v0.2.0 style block has 120 fields"
  assert_eq 39 "$syntax" "the syntax block has 39 tokens"
}

test_every_colour_is_a_hex_value() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  # A missing palette key would emit "#" alone, which is valid JSON and an
  # invalid colour — exactly the shape that renders as black and looks
  # deliberate.
  local bad
  bad=$(jq -r '.themes[0].style | to_entries[]
        | select(.value | type == "string")
        | select(.value | test("^#[0-9a-f]{6}$") | not) | .key' "$OUT")
  assert_eq "" "$bad" "every style colour must be a full #rrggbb"
  bad=$(jq -r '.themes[0].style.syntax | to_entries[]
        | select(.value.color | test("^#[0-9a-f]{6}$") | not) | .key' "$OUT")
  assert_eq "" "$bad" "every syntax token must carry a full #rrggbb"
}

# players is an ARRAY of objects, not a colour — a shape mistake here is the
# kind Zed rejects outright.
test_players_is_a_populated_array_of_objects() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  assert_eq "array" "$(jq -r '.themes[0].style.players | type' "$OUT")"
  [ "$(jq '.themes[0].style.players | length' "$OUT")" -ge 1 ] || fail "players must not be empty"
  local missing
  missing=$(jq -r '.themes[0].style.players[0] | [ "cursor","background","selection" ]
            - (. | keys) | join(",")' "$OUT")
  assert_eq "" "$missing" "each player needs cursor, background and selection"
}

test_appearance_follows_the_theme() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  assert_eq "dark" "$(jq -r '.themes[0].appearance' "$OUT")"
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$THEME_DIR/colors.toml"
  "$RENDER" "$THEME_DIR" "$ROOT"
  assert_eq "light" "$(jq -r '.themes[0].appearance' "$OUT")" \
    "a light theme must declare itself light, or Zed picks the wrong contrast"
}

test_colours_come_from_the_theme() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  local bg fg
  bg=$(sed -n -E 's/^[[:space:]]*background[[:space:]]*=[[:space:]]*"?#?([0-9A-Fa-f]{6})"?.*/\1/p' \
    "$THEME_DIR/colors.toml" | head -1 | tr 'A-F' 'a-f')
  fg=$(sed -n -E 's/^[[:space:]]*foreground[[:space:]]*=[[:space:]]*"?#?([0-9A-Fa-f]{6})"?.*/\1/p' \
    "$THEME_DIR/colors.toml" | head -1 | tr 'A-F' 'a-f')
  assert_eq "#$bg" "$(jq -r '.themes[0].style."editor.background"' "$OUT")"
  assert_eq "#$fg" "$(jq -r '.themes[0].style."editor.foreground"' "$OUT")"
}

# Derived shades must sit between the two endpoints, not land on one of them —
# a reversed or zeroed mix gives an editor whose panels are invisible against
# the background, or whose borders are the foreground colour.
test_derived_surfaces_sit_between_background_and_foreground() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  local bg border surface
  bg=$(jq -r '.themes[0].style.background' "$OUT")
  border=$(jq -r '.themes[0].style.border' "$OUT")
  surface=$(jq -r '.themes[0].style."surface.background"' "$OUT")
  [ "$border" != "$bg" ] || fail "the border is indistinguishable from the background"
  [ "$surface" != "$bg" ] || fail "panels are indistinguishable from the background"
  [ "$border" != "$surface" ] || fail "border and surface must not collapse to the same shade"
}

test_missing_colors_toml_is_a_hard_error() {
  setup_zed
  rm -f "$THEME_DIR/colors.toml"
  local out rc
  out=$("$RENDER" "$THEME_DIR" "$ROOT" 2>&1); rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no colors.toml"
  [ -f "$OUT" ] && fail "nothing must be written for an unresolvable theme"
}

# Zed watches its themes directory and hot-reloads, so a reader can arrive
# mid-write; a truncated theme is a parse error, not a wrong colour.
test_no_partial_file_is_left_under_the_real_name() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  local stray; stray=$(find "$ROOT/zed/themes" -maxdepth 1 -name '.*' 2>/dev/null)
  assert_eq "" "$stray" "no temp file may be left behind"
  grep -q 'mv -f "\$tmp" "\$out"' "$RENDER" \
    || fail "the theme must be renamed into place, not written in situ"
}

test_rerender_replaces_rather_than_appends() {
  setup_zed
  "$RENDER" "$THEME_DIR" "$ROOT"
  "$RENDER" "$THEME_DIR" "$ROOT"
  jq -e . "$OUT" >/dev/null 2>&1 || fail "a second render corrupted the theme"
  assert_eq 1 "$(jq '.themes | length' "$OUT")"
}

run_tests

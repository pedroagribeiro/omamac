#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
RENDER="$OMAMAC_ROOT/render/claude"

setup_claude() {
  CLAUDE_DIR="$TMPDIR_TEST/claude"
  THEME_DIR="$TMPDIR_TEST/theme"
  mkdir -p "$THEME_DIR"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$THEME_DIR/colors.toml"
  OUT="$CLAUDE_DIR/themes/omamac.json"
}

test_writes_a_valid_json_theme() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR" || fail "render exited non-zero"
  [ -f "$OUT" ] || { fail "no theme written"; return; }
  jq -e . "$OUT" >/dev/null 2>&1 || fail "theme is not valid JSON: $(cat "$OUT")"
}

# Claude Code only accepts "dark"/"light" for base, and every override must be
# a #rrggbb string. An empty or malformed value here is the failure mode that
# would make the whole theme silently fall back.
test_every_override_is_a_hex_colour_and_base_is_valid() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  local base; base=$(jq -r '.base' "$OUT")
  case "$base" in dark|light) ;; *) fail "base must be dark or light, got '$base'" ;; esac
  local bad
  bad=$(jq -r '.overrides | to_entries[] | select(.value | test("^#[0-9a-f]{6}$") | not) | "\(.key)=\(.value)"' "$OUT")
  assert_eq "" "$bad" "every override must be a #rrggbb colour"
  # And there must actually BE overrides — an empty object would pass the
  # check above vacuously.
  local n; n=$(jq '.overrides | length' "$OUT")
  [ "$n" -ge 30 ] || fail "expected the full override set, got $n keys"
}

test_carries_the_keys_the_installed_claude_code_uses() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  # fastMode is absent from Omarchy's template but present in a hand-written
  # theme already installed on this machine, so the installed Claude Code
  # understands it. Carrying the union is what keeps the indicator from
  # falling back to a colour that clashes with the rest of the theme.
  local k
  for k in claude text inverseText subtle success error warning planMode \
           bashBorder ide diffAdded diffRemoved selectionBg fastMode; do
    [ "$(jq -r --arg k "$k" '.overrides[$k] // empty' "$OUT")" != "" ] \
      || fail "missing override '$k'"
  done
}

# Sum of absolute per-channel differences between two #rrggbb colours.
colour_distance() {
  local a="${1#\#}" b="${2#\#}" i d=0 x y
  for i in 0 2 4; do
    x=$((16#${a:$i:2})); y=$((16#${b:$i:2}))
    d=$(( d + (x > y ? x - y : y - x) ))
  done
  printf '%s' "$d"
}

# The diff backgrounds are `mix background <colour> N%` — a SMALL nudge of the
# background toward green/red. Argument order is the whole game: reversed,
# `mix green background 15%` yields a near-solid green block that no diff is
# readable on, and every "is it interpolated" style check still passes because
# the value is still neither endpoint. So this pins the DIRECTION: the result
# must sit far closer to the background than to the accent colour it leans on.
test_diff_mixes_lean_only_slightly_off_the_background() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  local bg green added dimmed word
  bg=$(jq -r '.overrides.inverseText' "$OUT")
  green=$(jq -r '.overrides.success' "$OUT")
  added=$(jq -r '.overrides.diffAdded' "$OUT")
  dimmed=$(jq -r '.overrides.diffAddedDimmed' "$OUT")
  word=$(jq -r '.overrides.diffAddedWord' "$OUT")

  [ "$added" != "$bg" ] || fail "diffAdded was not mixed at all; it is just the background"

  local to_bg to_green
  to_bg=$(colour_distance "$added" "$bg")
  to_green=$(colour_distance "$added" "$green")
  [ "$to_bg" -lt "$to_green" ] || \
    fail "diffAdded is closer to the green ($to_green) than to the background ($to_bg) — the mix arguments are the wrong way round"

  # And the three strengths must order correctly away from the background:
  # 8% dimmed < 15% added < 32% word.
  local d8 d15 d32
  d8=$(colour_distance "$dimmed" "$bg")
  d15=$(colour_distance "$added" "$bg")
  d32=$(colour_distance "$word" "$bg")
  [ "$d8" -lt "$d15" ] || fail "the 8% mix is not dimmer than the 15% one ($d8 vs $d15)"
  [ "$d15" -lt "$d32" ] || fail "the 15% mix is not dimmer than the 32% one ($d15 vs $d32)"
}

test_light_theme_reports_light_base() {
  setup_claude
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$THEME_DIR/colors.toml"
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  assert_eq "light" "$(jq -r '.base' "$OUT")"
}

test_missing_colors_toml_is_a_hard_error() {
  setup_claude
  rm -f "$THEME_DIR/colors.toml"
  local out rc
  out=$("$RENDER" "$THEME_DIR" "$CLAUDE_DIR" 2>&1); rc=$?
  assert_eq 1 "$rc" "an unreadable theme must fail loudly, not write a black theme"
  assert_contains "$out" "no colors.toml"
  [ -f "$OUT" ] && fail "nothing must be written for an unresolvable theme"
}

# Claude Code watches this directory and hot-reloads, so a reader can arrive
# mid-write. Writing in place would expose a truncated file as valid-looking
# JSON; the rename is what makes that impossible.
test_no_partial_file_is_left_under_the_real_name() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  local stray; stray=$(find "$CLAUDE_DIR/themes" -maxdepth 1 -name '.*' 2>/dev/null)
  assert_eq "" "$stray" "no temp file may be left behind"
  # Structural: the renderer must not redirect straight at the destination.
  grep -q 'mv -f "\$tmp" "\$out"' "$RENDER" \
    || fail "the theme must be renamed into place, not written in situ"
}

test_rerender_replaces_rather_than_appends() {
  setup_claude
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  "$RENDER" "$THEME_DIR" "$CLAUDE_DIR"
  jq -e . "$OUT" >/dev/null 2>&1 || fail "a second render corrupted the theme"
}

run_tests

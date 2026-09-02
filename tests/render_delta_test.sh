#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
RENDER="$OMAMAC_ROOT/render/delta"

setup_delta() {
  ROOT="$TMPDIR_TEST/config"
  THEME_DIR="$TMPDIR_TEST/theme"
  mkdir -p "$THEME_DIR"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$THEME_DIR/colors.toml"
  OUT="$ROOT/git/omamac.ini"
}

# Parsed with git itself, not a regex: the file exists to be read by git, so
# git's own reading of it is the only opinion that counts.
cfg() { git config -f "$OUT" --get "$1"; }

test_writes_a_file_git_can_parse() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT" || fail "render exited non-zero"
  [ -f "$OUT" ] || { fail "nothing written"; return; }
  git config -f "$OUT" --list >/dev/null 2>&1 || fail "git cannot parse the generated include"
  assert_eq "omamac" "$(cfg delta.syntax-theme)" \
    "delta must be pointed at the bat theme omamac already generates"
}

# THE test in this file. `#` starts a comment in git config, so an unquoted
# #rrggbb truncates the line: `plus-style = syntax #2e3630` parses as the bare
# word "syntax" and the colour is silently gone — no error, delta just falls
# back to its defaults. Verified against real git: the unquoted form really
# does yield "syntax".
test_every_colour_survives_gits_comment_stripping() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT"
  local k v
  for k in delta.plus-style delta.plus-emph-style delta.minus-style delta.minus-emph-style; do
    v=$(cfg "$k")
    case "$v" in
      'syntax #'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) fail "$k lost its colour to comment stripping: got '$v'" ;;
    esac
  done
  for k in delta.line-numbers-plus-style delta.line-numbers-minus-style delta.line-numbers-zero-style; do
    v=$(cfg "$k")
    case "$v" in
      '#'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) fail "$k is not a hex colour after parsing: got '$v'" ;;
    esac
  done
}

# The bug this renderer exists to fix: a hardcoded `light = false` renders
# diffs for a dark background whatever the theme is.
test_light_follows_the_theme() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT"
  assert_eq "false" "$(cfg delta.light)" "a dark theme must report light=false"
  cp "$OMAMAC_ROOT/tests/fixtures/light/colors.toml" "$THEME_DIR/colors.toml"
  "$RENDER" "$THEME_DIR" "$ROOT"
  assert_eq "true" "$(cfg delta.light)" "a light theme must report light=true"
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

# Same mix-direction trap as render/claude: `mix background green 15%` is a
# faint tint of the background, but reversed it is a near-solid green block
# that no diff text is readable on — and it still looks like "a colour" to any
# check that only asks whether the value changed.
test_diff_tints_lean_only_slightly_off_the_background() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT"
  local bg green plus emph
  bg=$(sed -n -E 's/^[[:space:]]*background[[:space:]]*=[[:space:]]*"?(#?[0-9A-Fa-f]{6})"?.*/\1/p' \
    "$THEME_DIR/colors.toml" | head -1 | tr 'A-F' 'a-f'); bg="#${bg#\#}"
  green=$(cfg delta.line-numbers-plus-style)
  plus=$(cfg delta.plus-style); plus="${plus#syntax }"
  emph=$(cfg delta.plus-emph-style); emph="${emph#syntax }"

  local to_bg to_green
  to_bg=$(colour_distance "$plus" "$bg")
  to_green=$(colour_distance "$plus" "$green")
  [ "$to_bg" -lt "$to_green" ] || \
    fail "plus-style is closer to the green ($to_green) than to the background ($to_bg) — the mix arguments are reversed"
  # And the emphasis tint must be the stronger of the two.
  [ "$(colour_distance "$emph" "$bg")" -gt "$to_bg" ] || \
    fail "plus-emph-style must sit further from the background than plus-style"
}

test_missing_colors_toml_is_a_hard_error() {
  setup_delta
  rm -f "$THEME_DIR/colors.toml"
  local out rc
  out=$("$RENDER" "$THEME_DIR" "$ROOT" 2>&1); rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no colors.toml"
  [ -f "$OUT" ] && fail "nothing must be written for an unresolvable theme"
}

# git reads this include on every diff and every log, so a reader can arrive
# mid-write. A truncated include is a config parse error, not a wrong colour.
test_no_partial_file_is_left_under_the_real_name() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT"
  local stray; stray=$(find "$ROOT/git" -maxdepth 1 -name '.*' 2>/dev/null)
  assert_eq "" "$stray" "no temp file may be left behind"
  grep -q 'mv -f "\$tmp" "\$out"' "$RENDER" \
    || fail "the include must be renamed into place, not written in situ"
}

test_rerender_replaces_rather_than_appends() {
  setup_delta
  "$RENDER" "$THEME_DIR" "$ROOT"
  "$RENDER" "$THEME_DIR" "$ROOT"
  git config -f "$OUT" --list >/dev/null 2>&1 || fail "a second render corrupted the include"
  assert_eq 1 "$(grep -c '^\[delta\]' "$OUT")" "the [delta] section must be replaced, not duplicated"
}

run_tests

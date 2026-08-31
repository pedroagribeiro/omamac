#!/usr/bin/env bash
set -uo pipefail
# Read a colour from an Omarchy colors.toml. Prints 6-digit lowercase hex with
# no leading '#', or nothing if the key is absent.
#
# Real Omarchy colors.toml (v4.0.x release tags) has no color0..color15,
# cursor, selection_background or selection_foreground keys of its own — it
# names colours instead (red, green, blue, ..., bright_red, ..., selection,
# foreground). omamac_color tries the literal key first — so a file that DOES
# define e.g. `color4 = ...` explicitly still wins — then falls back to the
# alias chain in omamac_alias to reconcile the two schemas in this one place,
# so the five renderers can keep asking for the ANSI model unchanged.

# Candidate real keys for a synthetic ANSI/cursor/selection key, one per
# line, in priority order. Prints nothing for a key that needs no aliasing
# (it's expected to exist literally, e.g. background, foreground, accent).
omamac_alias() {
  case "$1" in
    color0|color8)        printf 'muted\n' ;;
    color1)                printf 'red\n' ;;
    color2)                printf 'green\n' ;;
    color3)                printf 'yellow\n' ;;
    color4)                printf 'blue\n' ;;
    color5)                printf 'magenta\n' ;;
    color6)                printf 'cyan\n' ;;
    color7)                printf 'foreground\n' ;;
    color9)                printf 'bright_red\n' ;;
    color10)               printf 'bright_green\n' ;;
    color11)               printf 'bright_yellow\n' ;;
    color12)               printf 'bright_blue\n' ;;
    color13)               printf 'bright_magenta\n' ;;
    color14)               printf 'bright_cyan\n' ;;
    color15|cursor)        printf 'bright_foreground\n' ;;
    selection_background)  printf 'selection\n' ;;
    selection_foreground)  printf 'foreground\n' ;;
  esac
}

# Raw lookup of one literal key, not yet lowercased, empty if absent. The key
# is anchored on both sides so `color1` cannot match `color15`.
_omamac_color_literal() {
  local file="$1" key="$2"
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?#?([0-9a-fA-F]{6})\"?[[:space:]]*\$/\1/p" "$file" | head -1
}

omamac_color() {
  local file="$1" key="$2" val alias
  [ -f "$file" ] || return 0
  val=$(_omamac_color_literal "$file" "$key")
  if [ -z "$val" ]; then
    while IFS= read -r alias; do
      [ -n "$alias" ] || continue
      val=$(_omamac_color_literal "$file" "$alias")
      [ -n "$val" ] && break
    done <<< "$(omamac_alias "$key")"
  fi
  [ -n "$val" ] || return 0
  printf '%s\n' "$val" | tr '[:upper:]' '[:lower:]'
}

# Print '#rrggbb' for a colour key. A theme missing the key must never produce
# a malformed line like `#` — warn and fall back, so the target's parser still
# reads valid syntax. Shared by every renderer that emits hex colours (ghostty,
# nvim, btop, bat) so a fallback or warning-format change happens in one place
# instead of four. $3 is the theme's display name for the warning (callers
# pass `basename "$theme_dir"`), not the file path.
omamac_hex_or_warn() {
  local toml="$1" key="$2" theme_name="$3" v
  v=$(omamac_color "$toml" "$key")
  if [ -z "$v" ]; then
    log_warn "theme ${theme_name} is missing colour '${key}'; using 000000"
    v="000000"
  fi
  printf '#%s' "$v"
}

# Exit 0 if the theme's background is light. Reads an explicit `mode` key
# first (Omarchy v4.0.x release tags ship one); falls back to computed
# integer sRGB relative luminance (2126 R, 7152 G, 722 B, scaled to 0..255;
# >=128 is light) only when a file has no `mode` key of its own.
omamac_is_light() {
  local file="$1" mode bg r g b lum
  mode=$(sed -n -E 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*"?(light|dark)"?[[:space:]]*$/\1/p' "$file" 2>/dev/null | head -1)
  case "$mode" in
    light) return 0 ;;
    dark)  return 1 ;;
  esac
  bg=$(omamac_color "$file" background)
  [ -n "$bg" ] || return 1
  r=$((16#${bg:0:2})); g=$((16#${bg:2:2})); b=$((16#${bg:4:2}))
  lum=$(((2126 * r + 7152 * g + 722 * b) / 10000))
  [ "$lum" -ge 128 ]
}

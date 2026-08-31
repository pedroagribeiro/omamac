#!/usr/bin/env bash
set -uo pipefail
# Read a colour from an Omarchy colors.toml. Prints 6-digit lowercase hex with
# no leading '#', or nothing if the key is absent.
omamac_color() {
  local file="$1" key="$2" val
  [ -f "$file" ] || return 0
  # The key is anchored on both sides so `color1` cannot match `color15`.
  val=$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?#?([0-9a-fA-F]{6})\"?[[:space:]]*\$/\1/p" "$file" | head -1)
  [ -n "$val" ] || return 0
  printf '%s\n' "$val" | tr '[:upper:]' '[:lower:]'
}

# Exit 0 if the theme's background is light. Integer sRGB relative luminance
# scaled to 0..255; >=128 is light. Omarchy 4 ships no light.mode marker.
omamac_is_light() {
  local bg r g b lum
  bg=$(omamac_color "$1" background)
  [ -n "$bg" ] || return 1
  r=$((16#${bg:0:2})); g=$((16#${bg:2:2})); b=$((16#${bg:4:2}))
  lum=$(((2126 * r + 7152 * g + 722 * b) / 10000))
  [ "$lum" -ge 128 ]
}

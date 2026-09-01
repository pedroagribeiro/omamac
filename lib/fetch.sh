#!/usr/bin/env bash
# lib/fetch.sh — the one way omamac pulls a file out of upstream Omarchy.
#
# Everything cached from upstream (theme backgrounds, theme preview shots)
# lands through omamac_fetch_atomic, so all of it inherits the same
# guarantee: a reader NEVER observes a partial file under its real name.
# That is not theoretical — it bit the wallpaper picker for real. `curl -o`
# writes straight into the destination as bytes arrive, so a second process
# listing the cache mid-download (the menu opening while a detached prefetch
# runs) saw a truncated file already sitting at the final name, offered it,
# and then failed to decode it. Downloading to a hidden sibling and renaming
# only on success fixes that: mv within one directory is atomic.
#
# The upstream revision is pinned to a RELEASE TAG, never a branch. Omarchy's
# master carries the legacy Omarchy 3 colour schema; the v4.0.x tags carry the
# named-colour + `mode` schema omamac actually renders. Tests point
# OMAMAC_OMARCHY_RAW at a file:// fixture tree and override the rev.
OMAMAC_FETCH="${OMAMAC_FETCH:-curl -fsSL}"
OMAMAC_OMARCHY_RAW="${OMAMAC_OMARCHY_RAW:-https://raw.githubusercontent.com/omacom/omarchy}"
OMAMAC_OMARCHY_REV="${OMAMAC_OMARCHY_REV:-v4.0.2}"

# omamac_fetch_atomic <url> <dest> — 0 on success (dest now exists), 1 otherwise
# (dest untouched, no temp file left behind).
omamac_fetch_atomic() {
  local url="$1" dest="$2" dir base part
  dir=$(dirname "$dest")
  base=$(basename "$dest")
  mkdir -p "$dir"
  part="${dir}/.${base}.part"
  rm -f "$part"
  # shellcheck disable=SC2086 # OMAMAC_FETCH is a command + flags, word-split on purpose.
  if $OMAMAC_FETCH -o "$part" "$url" 2>/dev/null; then
    mv -f "$part" "$dest"
    return 0
  fi
  # curl -o creates the output file BEFORE it knows the request failed, so the
  # cleanup is not optional: without it a zero-byte .part lingers forever, and
  # any listing that doesn't filter .part would serve it as a real entry.
  rm -f "$part"
  return 1
}

# The upstream path for one theme asset, e.g.
#   omamac_omarchy_url tokyo-night preview.png
#   omamac_omarchy_url tokyo-night "backgrounds/1-swirl.jpg"
omamac_omarchy_url() {
  printf '%s/%s/themes/%s/%s\n' "$OMAMAC_OMARCHY_RAW" "$OMAMAC_OMARCHY_REV" "$1" "$2"
}

#!/usr/bin/env bash
set -uo pipefail
OMAMAC_STATE="${OMAMAC_STATE:-$HOME/.local/state/omamac}"
OMAMAC_CACHE="${OMAMAC_CACHE:-$HOME/.cache/omamac}"

omamac_state_set() {
  mkdir -p "$OMAMAC_STATE"
  printf '%s\n' "$2" > "${OMAMAC_STATE}/$1"
}

omamac_state_get() {
  [ -f "${OMAMAC_STATE}/$1" ] || return 0
  cat "${OMAMAC_STATE}/$1"
}

# Remove a key entirely, so omamac_state_get reports it as unset rather than
# as an empty value. Needed to roll a speculative write back to "never chosen"
# — writing "" instead would make a caller that distinguishes unset from empty
# (e.g. font.size, where unset means "leave the user's own config alone")
# take the wrong branch.
omamac_state_clear() {
  rm -f "${OMAMAC_STATE}/$1"
}


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

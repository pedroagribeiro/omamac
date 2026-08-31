#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$OMAMAC_ROOT/lib/state.sh"

test_get_unset_key_is_empty_and_succeeds() {
  local v rc
  v=$(omamac_state_get theme.name); rc=$?
  assert_eq 0 "$rc" "get of unset key must succeed"
  assert_eq "" "$v"
}

test_set_then_get_roundtrips() {
  omamac_state_set theme.name "tokyo-night"
  assert_eq "tokyo-night" "$(omamac_state_get theme.name)"
}

test_set_overwrites_rather_than_appends() {
  omamac_state_set font "Menlo Nerd Font"
  omamac_state_set font "JetBrainsMono Nerd Font"
  assert_eq "JetBrainsMono Nerd Font" "$(omamac_state_get font)"
}

test_set_creates_state_dir() {
  rm -rf "$OMAMAC_STATE"
  omamac_state_set theme.name "nord"
  assert_eq "nord" "$(omamac_state_get theme.name)"
}

run_tests

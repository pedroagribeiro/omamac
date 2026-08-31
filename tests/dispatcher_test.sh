#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_unknown_verb_exits_1() {
  local out rc
  out=$("$OMAMAC_BIN" definitely-not-a-verb 2>&1); rc=$?
  assert_eq 1 "$rc" "unknown verb must exit 1"
  assert_contains "$out" "unknown command"
}

test_no_args_prints_usage() {
  local out
  out=$("$OMAMAC_BIN" 2>&1 || true)
  assert_contains "$out" "omamac <command>"
}

test_resolves_dir_through_symlink() {
  local link="$TMPDIR_TEST/omamac-link"
  ln -sf "$OMAMAC_BIN" "$link"
  assert_contains "$("$link" --print-dir)" "$OMAMAC_ROOT"
}

run_tests

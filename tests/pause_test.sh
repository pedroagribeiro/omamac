#!/usr/bin/env bash
# Pausing: the marker, the messages, and the guarantees that make it safe to
# reach for — that it changes no config, and that it tells you how to come back.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

MARKER_FILE() { printf '%s/paused\n' "$OMAMAC_STATE"; }

test_pause_writes_the_marker_and_resume_clears_it() {
  "$OMAMAC_BIN" pause >/dev/null
  [ -s "$(MARKER_FILE)" ] || fail "pause must leave a marker"
  "$OMAMAC_BIN" resume >/dev/null
  [ ! -f "$(MARKER_FILE)" ] || fail "resume must remove the marker"
}

test_status_exits_zero_only_while_paused() {
  "$OMAMAC_BIN" pause --status >/dev/null 2>&1 && fail "--status must be non-zero when active"
  "$OMAMAC_BIN" pause >/dev/null
  "$OMAMAC_BIN" pause --status >/dev/null 2>&1 || fail "--status must be zero when paused"
  "$OMAMAC_BIN" resume >/dev/null
  "$OMAMAC_BIN" pause --status >/dev/null 2>&1 && fail "--status must be non-zero again after resume"
}

# The menu closes as this runs and the hotkey that reopens it is being released,
# so stdout is the only chance to say how to get back. If this message ever
# stops naming the command, pausing becomes a trap.
test_pause_tells_you_how_to_come_back() {
  local out; out=$("$OMAMAC_BIN" pause)
  assert_contains "$out" "omamac resume"
  "$OMAMAC_BIN" resume >/dev/null
}

test_resume_confirms_on_stdout() {
  "$OMAMAC_BIN" pause >/dev/null
  assert_contains "$("$OMAMAC_BIN" resume)" "resumed"
}

# Pausing twice is not an error — the state is a fact, not a transition — but it
# must not re-stamp the time, or `doctor` would report "paused since" a moment
# that is not when it was paused.
test_pausing_twice_is_harmless_and_keeps_the_original_time() {
  "$OMAMAC_BIN" pause >/dev/null
  local first; first=$(cat "$(MARKER_FILE)")
  sleep 1.1
  "$OMAMAC_BIN" pause >/dev/null 2>&1 || fail "a second pause must not be an error"
  assert_eq "$first" "$(cat "$(MARKER_FILE)")" "a second pause must not restamp the time"
  "$OMAMAC_BIN" resume >/dev/null
}

test_resuming_when_active_is_harmless() {
  "$OMAMAC_BIN" resume >/dev/null 2>&1 || fail "resuming an active omamac must not be an error"
  [ ! -f "$(MARKER_FILE)" ] || fail "it must not create a marker"
}

# The second half of the pause message. `--since` is what doctor reads.
test_since_reports_when_and_nothing_when_active() {
  "$OMAMAC_BIN" pause --since >/dev/null 2>&1 && fail "--since must be non-zero when active"
  "$OMAMAC_BIN" pause >/dev/null
  local since; since=$("$OMAMAC_BIN" pause --since)
  printf '%s' "$since" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' \
    || fail "--since must print a timestamp, got '$since'"
  "$OMAMAC_BIN" resume >/dev/null
}

# The whole promise of this feature: it releases the hotkeys and touches nothing
# a tool reads. If pausing ever starts deleting generated themes, the pointers in
# the user's OWN config (Zed's "theme": "omamac", Claude's custom:omamac) would
# be left aimed at files that no longer exist.
test_pausing_changes_no_generated_theme_file() {
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/ghostty/themes" "$OMAMAC_CONFIG_ROOT/btop/themes" \
           "$OMAMAC_CONFIG_ROOT/zed/themes" "$OMAMAC_CONFIG_ROOT/git"
  printf 'background = #1a1b26\n' > "$OMAMAC_CONFIG_ROOT/ghostty/themes/omamac"
  printf 'theme[main_bg]="#1a1b26"\n'  > "$OMAMAC_CONFIG_ROOT/btop/themes/omamac.theme"
  printf '{"name":"omamac"}\n'         > "$OMAMAC_CONFIG_ROOT/zed/themes/omamac.json"
  printf '[delta]\n\tlight = false\n'  > "$OMAMAC_CONFIG_ROOT/git/omamac.ini"
  local before; before=$(find "$OMAMAC_CONFIG_ROOT" -type f | sort | xargs shasum | shasum)

  "$OMAMAC_BIN" pause >/dev/null
  local after; after=$(find "$OMAMAC_CONFIG_ROOT" -type f | sort | xargs shasum | shasum)
  assert_eq "$before" "$after" "pausing must not touch a single generated file"

  "$OMAMAC_BIN" resume >/dev/null
  local restored; restored=$(find "$OMAMAC_CONFIG_ROOT" -type f | sort | xargs shasum | shasum)
  assert_eq "$before" "$restored" "resuming must not touch them either"
}

test_an_unknown_argument_is_refused() {
  "$OMAMAC_BIN" pause --wat >/dev/null 2>&1 && fail "an unknown flag must exit non-zero"
  [ ! -f "$(MARKER_FILE)" ] || fail "a refused call must not change the state"
}

# ------------------------------------------------------------------ doctor --

# A paused omamac is a choice, not drift. Reporting it as a failure would train
# the user to ignore doctor; saying nothing at all leaves "my hotkey is dead"
# with no explanation anywhere.
test_doctor_reports_paused_without_failing() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"

  "$OMAMAC_BIN" pause >/dev/null
  local out; out=$("$OMAMAC_BIN" doctor 2>&1)
  assert_contains "$out" "PAUSED"
  assert_contains "$out" "omamac resume"
  case "$out" in *"FAIL  omamac"*) fail "being paused must not be reported as a failure" ;; esac

  "$OMAMAC_BIN" resume >/dev/null
  assert_contains "$("$OMAMAC_BIN" doctor 2>&1)" "active"
}

run_tests

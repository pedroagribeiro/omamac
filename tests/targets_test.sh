#!/usr/bin/env bash
# Switching individual targets off: the state, what a theme switch then skips,
# and what doctor says about it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

DISABLED() { printf '%s/disabled\n' "$OMAMAC_STATE"; }

test_everything_is_on_before_anything_is_written() {
  # Absence means enabled, so a fresh install needs no file to exist first.
  [ ! -f "$(DISABLED)" ] || fail "precondition: no state yet"
  local out; out=$("$OMAMAC_BIN" targets)
  assert_eq 10 "$(printf '%s' "$out" | grep -c ' on ')" "all ten targets on by default"
  assert_eq 0 "$(printf '%s' "$out" | grep -c ' off ')" "none off by default"
}

test_disable_and_enable_round_trip() {
  "$OMAMAC_BIN" targets --disable aerospace >/dev/null
  "$OMAMAC_BIN" targets --enabled aerospace && fail "aerospace must read as off"
  assert_contains "$("$OMAMAC_BIN" targets)" "off  aerospace"
  "$OMAMAC_BIN" targets --enable aerospace >/dev/null
  "$OMAMAC_BIN" targets --enabled aerospace || fail "aerospace must read as on again"
}

test_toggle_flips_and_reports_the_label() {
  assert_contains "$("$OMAMAC_BIN" targets --toggle btop)" "btop off"
  assert_contains "$("$OMAMAC_BIN" targets --toggle btop)" "btop on"
}

# The label is for people; the name is the thing. `macOS appearance` must never
# reach the CLI.
test_the_list_carries_name_label_and_state() {
  "$OMAMAC_BIN" targets --disable macos >/dev/null
  local line; line=$("$OMAMAC_BIN" targets --list | grep '^macos')
  assert_eq "macos	macOS appearance	off" "$line" "name, label and state, tab separated"
}

test_switching_one_off_leaves_the_others_alone() {
  "$OMAMAC_BIN" targets --disable zed >/dev/null
  assert_eq 9 "$("$OMAMAC_BIN" targets | grep -c ' on ')" "only zed goes off"
  "$OMAMAC_BIN" targets --enabled ghostty || fail "ghostty must be unaffected"
}

# Whole-line matching, not substring. No CURRENT pair of target names collides,
# so disabling one and checking another proves nothing — this writes the state
# by hand to make the collision that the -x flag exists for. Without it,
# `grep -F ghostty` matches the line "ghostty-extra" and reports a target that
# is on as off.
test_a_longer_name_in_the_list_does_not_switch_off_a_shorter_one() {
  mkdir -p "$OMAMAC_STATE"
  printf 'ghostty-extra\n' > "$(DISABLED)"
  "$OMAMAC_BIN" targets --enabled ghostty \
    || fail "a line that merely CONTAINS 'ghostty' must not switch ghostty off"
  assert_contains "$("$OMAMAC_BIN" targets)" "on   ghostty"
}

test_repeating_a_disable_does_not_duplicate_it() {
  "$OMAMAC_BIN" targets --disable delta >/dev/null
  "$OMAMAC_BIN" targets --disable delta >/dev/null
  assert_eq 1 "$(grep -c '^delta$' "$(DISABLED)")" "the list must hold each name once"
}

test_an_unknown_target_is_refused_and_says_what_is_known() {
  local out; out=$("$OMAMAC_BIN" targets --disable nosuchthing 2>&1)
  [ $? -ne 0 ] || fail "an unknown target must exit non-zero"
  assert_contains "$out" "unknown target"
  assert_contains "$out" "ghostty"
  [ ! -f "$(DISABLED)" ] || fail "a refused call must not write state"
}

# ------------------------------------------------------- the theme switch --

# Stubs every renderer so a switch records who ran rather than writing anything.
setup_theme_run() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export RAN="$TMPDIR_TEST/ran"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night" "$OMAMAC_CONFIG_ROOT"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  rm -f "$RAN"
}

# Runs a real theme switch against a copy of the tree whose render/ scripts are
# replaced by recorders, so this observes which ones the switch actually starts.
theme_switch_runs() {
  local tree="$TMPDIR_TEST/tree"
  if [ ! -d "$tree" ]; then
    mkdir -p "$tree"
    cp -R "$OMAMAC_ROOT/bin" "$OMAMAC_ROOT/lib" "$tree/"
    mkdir -p "$tree/render"
    for r in ghostty nvim btop bat delta zed claude macos; do
      printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$RAN"\n' "$r" > "$tree/render/$r"
      chmod +x "$tree/render/$r"
    done
  fi
  OMAMAC_DIR="$tree" "$tree/bin/omamac" theme tokyo-night >/dev/null 2>&1
  sort "$RAN" 2>/dev/null | tr '\n' ' '
}

test_a_switch_runs_every_renderer_when_all_are_on() {
  setup_theme_run
  local ran; ran=$(theme_switch_runs)
  for r in ghostty nvim btop bat delta zed claude macos; do
    case " $ran " in *" $r "*) ;; *) fail "$r should have run" ;; esac
  done
}

# The whole point: switched off means omamac does not touch it.
test_a_switch_skips_the_renderers_that_are_off() {
  setup_theme_run
  "$OMAMAC_BIN" targets --disable btop >/dev/null
  "$OMAMAC_BIN" targets --disable zed >/dev/null
  local ran; ran=$(theme_switch_runs)
  case " $ran " in *" btop "*) fail "btop is off and must not run" ;; esac
  case " $ran " in *" zed "*) fail "zed is off and must not run" ;; esac
  # And the rest still do.
  case " $ran " in *" nvim "*) ;; *) fail "nvim should still run" ;; esac
  case " $ran " in *" ghostty "*) ;; *) fail "ghostty should still run" ;; esac
}

test_ghostty_can_be_switched_off_too() {
  setup_theme_run
  "$OMAMAC_BIN" targets --disable ghostty >/dev/null
  local ran; ran=$(theme_switch_runs)
  case " $ran " in *" ghostty "*) fail "ghostty is off and must not run" ;; esac
  case " $ran " in *" nvim "*) ;; *) fail "the others must still run" ;; esac
}

# ------------------------------------------------------------------ doctor --

setup_doctor() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

# Files left behind by an earlier render are not drift once omamac has been told
# to stop writing them — but they are not `ok` either, since nothing is keeping
# them current. One `skip` line, said once.
test_doctor_skips_a_switched_off_target_instead_of_failing_it() {
  setup_doctor
  local before; before=$("$OMAMAC_BIN" doctor 2>&1 | grep -c "FAIL  btop")
  [ "$before" -gt 0 ] || fail "precondition: btop should be failing with no files"
  "$OMAMAC_BIN" targets --disable btop >/dev/null
  local out; out=$("$OMAMAC_BIN" doctor 2>&1)
  assert_eq 0 "$(printf '%s' "$out" | grep -c 'FAIL  btop')" "a switched-off target must not FAIL"
  assert_eq 1 "$(printf '%s' "$out" | grep -c 'skip  btop')" "it must be announced exactly once"
  assert_contains "$out" "switched off"
}

# doctor's column says `aero` and `bg` where the targets are `aerospace` and
# `wallpaper`. If that mapping is wrong the switch silently does nothing here.
test_doctors_short_column_names_map_onto_target_names() {
  setup_doctor
  "$OMAMAC_BIN" targets --disable aerospace >/dev/null
  "$OMAMAC_BIN" targets --disable wallpaper >/dev/null
  local out; out=$("$OMAMAC_BIN" doctor 2>&1)
  # The MESSAGE, not just a skip line: doctor already skips `aero` when there is
  # no template, so counting skips cannot tell whether the mapping worked.
  assert_eq 1 "$(printf '%s' "$out" | grep -c 'aero .*switched off')" \
    "aerospace must map onto the aero column"
  assert_eq 1 "$(printf '%s' "$out" | grep -c 'bg .*switched off')" \
    "wallpaper must map onto the bg column"
}

run_tests

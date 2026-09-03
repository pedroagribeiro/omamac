#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# AeroSpace's gaps can only be changed by editing its config: the CLI is
# read-only, there is no include mechanism and no --config-path override. So
# omamac renders the config from a TEMPLATE whose omamac-owned values carry a
# trailing `# omamac:gaps` marker. The template is a complete, valid config in
# its own right — the marked lines hold real defaults, not placeholders — so
# nothing breaks if omamac never runs.
setup_aero() {
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  mkdir -p "$OMAMAC_CONFIG_ROOT/aerospace"
  TEMPLATE="$OMAMAC_CONFIG_ROOT/aerospace/aerospace.template.toml"
  OUT="$OMAMAC_CONFIG_ROOT/aerospace/aerospace.toml"
  cat > "$TEMPLATE" <<'EOF'
start-at-login = false
on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
accordion-padding = 30

# Values marked `# omamac:gaps` below are rewritten by omamac. This sentence
# mentions the marker in PROSE, exactly as the real template does — anything
# counting marked lines has to count assignments, not mentions.

[gaps]
  inner.horizontal = 10  # omamac:gaps
  inner.vertical =   10  # omamac:gaps
  outer.left =       10  # omamac:gaps
  outer.bottom =     10  # omamac:gaps
  outer.top =        10  # omamac:gaps
  outer.right =      10  # omamac:gaps

[mode.main.binding]
  alt-h = 'focus left'
  alt-2 = 'workspace 2'
EOF
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$AERO_LOG"\nexit 0\n' > "$TMPDIR_TEST/aerospace"
  chmod +x "$TMPDIR_TEST/aerospace"
  export OMAMAC_AEROSPACE="$TMPDIR_TEST/aerospace" AERO_LOG="$TMPDIR_TEST/aero.log"
  : > "$AERO_LOG"
}

test_list_is_a_pixel_range() {
  setup_aero
  local out; out=$("$OMAMAC_BIN" aerospace --list)
  assert_eq "0" "$(printf '%s\n' "$out" | head -1)"
  assert_eq "40" "$(printf '%s\n' "$out" | tail -1)"
  assert_eq 21 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "0..40 in steps of 2"
}

test_current_reads_the_template_before_anything_is_chosen() {
  setup_aero
  assert_eq "10" "$("$OMAMAC_BIN" aerospace --current)" \
    "the template's own value is the default, so the picker can mark a row"
}

test_current_prefers_state_once_chosen() {
  setup_aero
  "$OMAMAC_BIN" aerospace 4 >/dev/null 2>&1
  assert_eq "4" "$("$OMAMAC_BIN" aerospace --current)"
}

test_set_rewrites_every_marked_value() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  [ -f "$OUT" ] || { fail "no config rendered"; return; }
  assert_eq 6 "$(grep -c '= *6 *# omamac:gaps' "$OUT")" "all six gap values must move together"
  assert_eq 0 "$(grep -c '= *10 *# omamac:gaps' "$OUT")" "no marked value may be left at the old number"
}

# The whole point of rendering rather than editing: everything the user wrote
# has to survive untouched, or omamac is silently rewriting their config.
test_render_leaves_the_rest_of_the_config_alone() {
  setup_aero
  "$OMAMAC_BIN" aerospace 8 >/dev/null 2>&1
  assert_contains "$(cat "$OUT")" "on-focused-monitor-changed = ['move-mouse monitor-lazy-center']"
  assert_contains "$(cat "$OUT")" "alt-h = 'focus left'"
  assert_contains "$(cat "$OUT")" "[mode.main.binding]"
  # ...including UNMARKED NUMBERS. This is the assertion that matters: a
  # substitution that keys off "= <digits>" rather than off the marker would
  # rewrite accordion-padding too, and quoted values like 'workspace 2' would
  # not catch it because they do not start with a digit.
  assert_contains "$(cat "$OUT")" "accordion-padding = 30"
  assert_contains "$(cat "$OUT")" "alt-2 = 'workspace 2'"
  assert_eq "$(grep -c . "$TEMPLATE")" "$(grep -c . "$OUT")" "the rendered file must have the same shape as the template"
}

test_the_marker_survives_so_a_rerender_still_works() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  "$OMAMAC_BIN" aerospace 12 >/dev/null 2>&1
  assert_eq 6 "$(grep -c '= *12 *# omamac:gaps' "$OUT")" \
    "a second render must find the markers again"
}

# --dry-run first: a config AeroSpace rejects would otherwise be adopted, and
# the failure would only show up in its own logs.
test_validates_before_reloading() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  local log; log=$(cat "$AERO_LOG")
  assert_contains "$log" "reload-config --dry-run"
  assert_contains "$log" "reload-config"
  # The dry run must come first.
  [ "$(printf '%s\n' "$log" | head -1)" = "reload-config --dry-run" ] \
    || fail "the dry run must precede the real reload, got: $log"
}

test_a_rejected_config_is_not_reloaded_and_the_value_reverts() {
  setup_aero
  "$OMAMAC_BIN" aerospace 4 >/dev/null 2>&1        # a good value first
  printf '#!/usr/bin/env bash\ncase "$*" in *--dry-run*) exit 1 ;; esac\nprintf "%%s\\n" "$*" >> "$AERO_LOG"\nexit 0\n' \
    > "$TMPDIR_TEST/aerospace"
  chmod +x "$TMPDIR_TEST/aerospace"
  : > "$AERO_LOG"
  local rc
  "$OMAMAC_BIN" aerospace 8 >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a config AeroSpace rejects must be reported as a failure"
  case "$(cat "$AERO_LOG")" in
    *"reload-config"*) [ -n "$(grep -v -- '--dry-run' "$AERO_LOG")" ] && fail "must not reload a config that failed validation" ;;
  esac
  assert_eq "4" "$("$OMAMAC_BIN" aerospace --current)" "the rejected value must not be recorded"
}

test_out_of_range_and_non_numeric_are_refused() {
  setup_aero
  local rc
  for bad in 41 -2 abc 4.5; do
    "$OMAMAC_BIN" aerospace "$bad" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] || fail "gaps '$bad' should have been refused, exited $rc"
  done
  [ -f "$OMAMAC_STATE/aerospace.gaps" ] && fail "a refused value must not be recorded"
}

test_missing_template_is_reported_not_silently_skipped() {
  setup_aero
  rm -f "$TEMPLATE"
  local out rc
  out=$("$OMAMAC_BIN" aerospace 6 2>&1); rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no aerospace template"
}

test_render_reapplies_the_current_value_without_changing_it() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  rm -f "$OUT"
  "$OMAMAC_BIN" aerospace --render >/dev/null 2>&1
  assert_eq 6 "$(grep -c '= *6 *# omamac:gaps' "$OUT")" \
    "--render must rebuild the config from the template at the chosen value"
  assert_eq "6" "$("$OMAMAC_BIN" aerospace --current)"
}

test_no_partial_file_is_left_behind() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  local stray; stray=$(find "$OMAMAC_CONFIG_ROOT/aerospace" -maxdepth 1 -name '.*' 2>/dev/null)
  assert_eq "" "$stray"
  grep -q 'mv -f "\$tmp" "\$OUT"' "$OMAMAC_ROOT/bin/omamac-aerospace" \
    || fail "the config must be renamed into place, not written in situ"
}

# A template that documents its own convention says `# omamac:gaps` in a
# comment. The renderer is safe by construction (its patterns are anchored on
# ^[^#]*, so a comment line cannot match), but anything COUNTING marked lines
# has to count assignments rather than mentions — doctor read the prose as a
# seventh gap that never matched, and reported a correctly rendered config as
# broken.
test_a_prose_mention_of_the_marker_is_not_treated_as_a_value() {
  setup_aero
  "$OMAMAC_BIN" aerospace 6 >/dev/null 2>&1
  # The comment survives untouched...
  assert_contains "$(cat "$OUT")" "mentions the marker in PROSE"
  # ...and exactly the six assignments carry the new value.
  assert_eq 6 "$(grep -cE '=[[:space:]]*6[[:space:]]*# omamac:gaps' "$OUT")"
  assert_eq 6 "$(grep -cE '=[[:space:]]*[0-9]+[[:space:]]*# omamac:gaps' "$OUT")" \
    "only assignments count as marked values"
}

run_tests

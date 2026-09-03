#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_slack() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
  printf '#!/usr/bin/env bash\ncat > "$PB_OUT"\n' > "$TMPDIR_TEST/pbcopy"
  chmod +x "$TMPDIR_TEST/pbcopy"
  export OMAMAC_PBCOPY="$TMPDIR_TEST/pbcopy" PB_OUT="$TMPDIR_TEST/clipboard"
  rm -f "$PB_OUT"
}

theme_colour() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?#?([0-9A-Fa-f]{6})\"?.*/\1/p" \
    "$OMAMAC_THEMES_DIR/tokyo-night/colors.toml" | head -1 | tr 'A-F' 'a-f'
}

# Slack's custom sidebar theme has no keys — it is eight colours in a fixed
# order, so the ORDER is the entire format and a wrong slot is invisible until
# you look at the sidebar. Each position is pinned to the palette key it must
# carry.
test_emits_eight_colours_in_slacks_order() {
  setup_slack
  local out; out=$("$OMAMAC_BIN" slack)
  assert_eq 8 "$(printf '%s' "$out" | tr ',' '\n' | grep -c .)" "Slack takes exactly eight colours"
  # Every field a #rrggbb — a missing palette key would emit "#" alone.
  local bad; bad=$(printf '%s' "$out" | tr ',' '\n' | grep -vcE '^#[0-9a-f]{6}$')
  assert_eq 0 "$bad" "every slot must be a full hex colour"

  local -a f
  IFS=',' read -r -a f <<< "$out"
  assert_eq "#$(theme_colour background)"           "${f[0]}" "1: Column BG"
  assert_eq "#$(theme_colour accent)"               "${f[2]}" "3: Active Item"
  assert_eq "#$(theme_colour background)"           "${f[3]}" "4: Active Item Text"
  # `selection`, not `selection_background`: the v4 themes use named colours and
  # lib/colors.sh resolves selection_background onto `selection` through its
  # alias chain. Reading the file literally here would assert against a key the
  # fixture does not have — which is what this test did first, and it looked
  # like a bug in the renderer rather than in the test.
  assert_eq "#$(theme_colour selection)"            "${f[4]}" "5: Hover Item"
  assert_eq "#$(theme_colour foreground)"           "${f[5]}" "6: Text Color"
  assert_eq "#$(theme_colour green)"                "${f[6]}" "7: Active Presence"
  assert_eq "#$(theme_colour red)"                  "${f[7]}" "8: Mention Badge"
  # 2 is a mix, so it must be neither endpoint.
  [ "${f[1]}" != "${f[0]}" ] || fail "2: Menu BG Hover must differ from the column background"
}

test_copy_puts_exactly_the_string_on_the_clipboard() {
  setup_slack
  "$OMAMAC_BIN" slack --copy >/dev/null
  assert_eq "$("$OMAMAC_BIN" slack)" "$(cat "$PB_OUT")" \
    "the clipboard must carry the same string the plain form prints"
  # No trailing newline: Slack's paste box treats it as part of the value.
  [ "$(wc -l < "$PB_OUT" | tr -d ' ')" -eq 0 ] || fail "the copied string must not end in a newline"
}

# The menu closes as this runs, so stdout is the only way the user learns it
# worked — the Hammerspoon host surfaces an applied command's stdout as an
# alert. Every log_* goes to stderr precisely so this channel stays clean.
test_copy_confirms_on_stdout_for_the_menu_alert() {
  setup_slack
  local out; out=$("$OMAMAC_BIN" slack --copy 2>/dev/null)
  assert_contains "$out" "copied"
  assert_contains "$out" "tokyo-night"
  case "$out" in
    *"#"*) fail "the confirmation must not be the colour string itself; it is shown as an alert" ;;
  esac
}

test_plain_form_prints_only_the_string() {
  setup_slack
  local out; out=$("$OMAMAC_BIN" slack 2>/dev/null)
  case "$out" in
    "#"*) ;;
    *) fail "without --copy the output must be the theme string alone, got: $out" ;;
  esac
}

test_a_failed_copy_is_reported() {
  setup_slack
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMPDIR_TEST/pbcopy-broken"
  chmod +x "$TMPDIR_TEST/pbcopy-broken"
  export OMAMAC_PBCOPY="$TMPDIR_TEST/pbcopy-broken"
  local out rc
  out=$("$OMAMAC_BIN" slack --copy 2>&1); rc=$?
  assert_eq 1 "$rc" "a clipboard that refused the string must not report success"
  assert_contains "$out" "could not copy"
}

test_no_theme_applied_is_an_error() {
  setup_slack
  rm -f "$OMAMAC_STATE/theme.name"
  local out rc
  out=$("$OMAMAC_BIN" slack 2>&1); rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no theme applied"
}

run_tests

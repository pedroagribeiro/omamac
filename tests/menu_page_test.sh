#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
PAGE="$OMAMAC_ROOT/menu/menu.html"
DRIVER="$OMAMAC_ROOT/tests/menu_page_driver.js"

# Pull out the page's script block so a JS engine can parse it.
extract_js() { awk '/<script>/{f=1;next} /<\/script>/{f=0} f' "$PAGE"; }

# Actually run the page's script in a minimal DOM shim and return the JSON
# array of messages it posted to window.webkit.messageHandlers.omamac.
# $1 = window.OMAMAC JSON, $2 = scenario name (see menu_page_driver.js).
run_driver() {
  OMAMAC_JSON="$1" node "$DRIVER" "$PAGE" "$2"
}

test_page_is_self_contained() {
  [ -f "$PAGE" ] || { fail "menu/menu.html missing"; return; }
  # The host loads this as a string, so any remote asset would silently fail.
  case "$(cat "$PAGE")" in
    *'src="http'*|*'href="http'*) fail "page references a remote asset" ;;
  esac
}

test_script_block_parses() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to parse menu.html — cannot verify the page"
    return
  fi
  extract_js > "$TMPDIR_TEST/menu.js"
  [ -s "$TMPDIR_TEST/menu.js" ] || { fail "no <script> block found in menu.html"; return; }
  node --check "$TMPDIR_TEST/menu.js" 2>"$TMPDIR_TEST/err" \
    || fail "menu.html script does not parse: $(cat "$TMPDIR_TEST/err")"
}

test_declares_the_host_message_contract() {
  local js; js=$(extract_js)
  assert_contains "$js" "window.OMAMAC"
  assert_contains "$js" "messageHandlers"
  assert_contains "$js" '"apply"'
  assert_contains "$js" '"preview"'
  assert_contains "$js" '"close"'
  assert_contains "$js" "omamacSetPreview"
}

test_enter_on_a_theme_posts_an_apply_bound_to_that_theme() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # sel resets to 0 after the root->submenu transition, so "gruvbox" (index 0
  # of theme.options) is what the second Enter must select. Root -> Theme is
  # the first Enter; select is the second.
  local data='{"theme":{"current":"nord","options":["gruvbox","nord"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "enter-enter")
  local msg; msg=$(printf '%s' "$out" | jq -c '.[-1]')
  # Assert action, cmd AND arg together, on the SAME message — not just that
  # each substring appears somewhere in the messages array. That is what
  # makes an apply/preview action-string swap impossible to slip through:
  # a swap still contains every substring, it just binds them to the wrong
  # message.
  assert_eq '{"action":"apply","cmd":"theme","arg":"gruvbox"}' "$msg"
}

test_escape_at_root_posts_close() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "escape")
  local msg; msg=$(printf '%s' "$out" | jq -c '.[-1]')
  assert_eq '{"action":"close"}' "$msg"
}

run_tests

#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
PAGE="$OMAMAC_ROOT/menu/menu.html"

# Pull out the page's script block so a JS engine can parse it.
extract_js() { awk '/<script>/{f=1;next} /<\/script>/{f=0} f' "$PAGE"; }

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

run_tests

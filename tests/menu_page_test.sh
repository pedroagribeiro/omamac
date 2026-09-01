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
  # Entering a level selects that level's CURRENT value, the way both Omarchy
  # switchers pass --selected to omarchy-menu-images. theme.current is "nord"
  # — the SECOND option — so the second Enter must apply "nord", not the
  # first option. Fixture deliberately puts "nord" neither first nor last, so
  # neither an index-0 nor an index-(n-1) default could pass by accident.
  local data='{"theme":{"current":"nord","options":["gruvbox","nord","rose-pine"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "enter-enter")
  local msg; msg=$(printf '%s' "$out" | jq -c '.[-1]')
  # Assert action, cmd AND arg together, on the SAME message — not just that
  # each substring appears somewhere in the messages array. That is what
  # makes an apply/preview action-string swap impossible to slip through:
  # a swap still contains every substring, it just binds them to the wrong
  # message.
  assert_eq '{"action":"apply","cmd":"theme","arg":"nord"}' "$msg"
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

test_preview_is_requested_only_once_per_name_across_renders() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Three renders of the Background level, no thumbnail ever supplied by the
  # host in between (omamacSetPreview is never called). Without a per-name
  # "already requested" guard, every render re-sends a preview request for
  # every name still lacking a thumbnail — O(N^2) sips spawns, and it never
  # stops for a wallpaper whose conversion keeps failing.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["a.jpg","b.jpg","c.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-render-thrice")
  local previews; previews=$(printf '%s' "$out" | jq -c '[.[] | select(.action == "preview")]')
  local total; total=$(printf '%s' "$previews" | jq 'length')
  assert_eq 3 "$total" "each of the 3 background names must be requested exactly once across 3 renders"
  local a_count; a_count=$(printf '%s' "$previews" | jq '[.[] | select(.name == "a.jpg")] | length')
  assert_eq 1 "$a_count" "a.jpg must be requested exactly once, not once per render"
}

test_entering_background_requests_previews_and_enter_applies_the_selected_item() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # root -> Background renders the coverflow immediately, which must
  # lazily request a preview for every visible item exactly like the old
  # list view did. ArrowRight (the coverflow's own selection key, per
  # Omarchy's ImagePicker.qml) then Enter must post apply/bg bound to
  # whichever item that leaves selected — "sunset.jpg", the SECOND
  # background — not just whatever sel happened to default to.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["dawn.jpg","sunset.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-select-apply")
  local previews; previews=$(printf '%s' "$out" | jq -c '[.[] | select(.action == "preview") | .name] | sort')
  assert_eq '["dawn.jpg","sunset.jpg"]' "$previews" "entering Background must request a preview for every visible item"
  local msg; msg=$(printf '%s' "$out" | jq -c '.[-1]')
  # Same discipline as the theme test above: action, cmd AND arg asserted
  # together on the one message Enter actually posts, so an apply/preview
  # action-string swap — or a swap that binds arg to the wrong item — can't
  # slip through.
  assert_eq '{"action":"apply","cmd":"bg","arg":"sunset.jpg"}' "$msg"
}

test_header_shows_typed_text_instead_of_placeholder() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # There is no visible input box: the header line doubles as the search
  # display. With nothing typed it shows "<Level>…" dimmed; the moment the
  # user types, it must show exactly what they typed, not the placeholder.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "type-then-report")
  local head_text; head_text=$(printf '%s' "$out" | jq -r '.headText')
  local head_class; head_class=$(printf '%s' "$out" | jq -r '.headClass')
  assert_eq "the" "$head_text" "header must show the typed text, not the placeholder, once characters are typed"
  assert_eq "typed" "$head_class" "header must switch to full opacity once characters are typed"
}

test_empty_preview_permits_one_retry_then_gives_up() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # A single Background item. Entering the level requests one preview
  # (attempt 1); omamacSetPreview(name, "") called twice in a row simulates
  # the host reporting a failed/still-downloading preview both times it
  # asked. The bounded retry means exactly ONE more request goes out after
  # the first empty response (attempt 2) — never a third — and the
  # placeholder must survive throughout: no <img> is ever appended.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["only.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-empty-preview-retry-cap")
  local previews; previews=$(printf '%s' "$out" | jq -c '[.messages[] | select(.action == "preview" and .name == "only.jpg")] | length')
  assert_eq 2 "$previews" "an empty preview must permit exactly one retry (2 requests total), then stop"
  local has_img; has_img=$(printf '%s' "$out" | jq -r '.hasImg')
  assert_eq "false" "$has_img" "an empty preview must never be cached/rendered as a broken <img>; the placeholder must remain"
}


# ---------------------------------------------------------------------------
# The Theme level is a coverflow, not a list.
#
# Upstream, Theme and Background are the SAME picker: both switchers shell
# out to omarchy-menu-images, and omarchy.image-picker's manifest calls
# itself the "Image-grid selector overlay used for wallpapers, themes, and
# any other directory of images". The only difference is the flags —
# omarchy-theme-switcher adds --show-labels --filterable, which is what puts
# the theme name (and the typed filter) under the strip.
# ---------------------------------------------------------------------------

test_theme_level_renders_the_coverflow_and_not_the_list() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"nord","options":["gruvbox","nord","rose-pine"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-open-and-report")

  assert_eq "true"  "$(printf '%s' "$out" | jq -r '.cardHidden')" "the 300px card must be hidden at the Theme level"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.cvHidden')"   "the picker overlay must be shown at the Theme level"
  assert_eq 3 "$(printf '%s' "$out" | jq '.strip.count')" "every theme must get a coverflow item"
  # The dull list is what this replaces: if renderList still ran for this
  # level the rows would be sitting in #list.
  assert_eq 0 "$(printf '%s' "$out" | jq '.strip.listCount')" "the Theme level must not also populate the flat list"
  # ...opened on the CURRENT theme (index 1 of three), not index 0.
  assert_eq 1 "$(printf '%s' "$out" | jq '.strip.selectedIndex')" "the coverflow must open on the current theme"
}

test_theme_level_requests_a_preview_per_theme_with_the_theme_kind() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"nord","options":["gruvbox","nord","rose-pine"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-open-and-report")
  # kind asserted TOGETHER with the name on each message: the host routes on
  # it (kind=theme -> `omamac preview --theme <name>`), so a request that
  # carried the right names with the wrong kind would silently look up
  # wallpapers of the current theme and come back empty for all three.
  local previews; previews=$(printf '%s' "$out" | jq -c '[.messages[] | select(.action == "preview") | {name, kind}] | sort_by(.name)')
  assert_eq '[{"name":"gruvbox","kind":"theme"},{"name":"nord","kind":"theme"},{"name":"rose-pine","kind":"theme"}]' \
    "$previews" "each theme must be previewed once, as kind=theme"
}

test_theme_level_labels_the_selected_theme_omarchy_style() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # ImagePickerModel.labelForPath: extension stripped, -/_ runs to spaces,
  # each word capitalised. "tokyo-night" -> "Tokyo Night".
  local data='{"theme":{"current":"tokyo-night","options":["gruvbox","tokyo-night"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-open-and-report")
  assert_eq "Tokyo Night" "$(printf '%s' "$out" | jq -r '.labelText')" \
    "the label must be the SELECTED theme's name, title-cased like Omarchy's labelForPath"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.labelHidden')" "--show-labels: the Theme level must show a label"
  # bottomChromeHeight with showLabels && filterable.
  assert_eq "104px" "$(printf '%s' "$out" | jq -r '.chrome')" "the Theme level reserves Omarchy's labelled chrome height"
}

test_background_level_has_no_label_matching_the_upstream_switcher() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # omarchy-theme-bg-switcher passes NEITHER --show-labels nor --filterable,
  # so its picker is a bare strip with 30px of chrome under it. The Theme
  # level's label must not leak across to it.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["dawn.jpg","sunset.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-select-apply")
  assert_eq '{"action":"apply","cmd":"bg","arg":"sunset.jpg"}' "$(printf '%s' "$out" | jq -c '.[-1]')"
}

test_theme_filter_with_no_match_shows_omarchys_no_matches_label() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # currentLabel(): with a filter typed and nothing matching, upstream shows
  # "No matches" rather than a stale name or an empty line.
  local data='{"theme":{"current":"nord","options":["gruvbox","nord"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-filter-no-match")
  assert_eq 0 "$(printf '%s' "$out" | jq '.strip.count')" "a filter matching nothing must empty the strip"
  assert_eq "No matches" "$(printf '%s' "$out" | jq -r '.labelText')"
  # --filterable: what was typed is echoed under the label, since the card
  # (and its header) is hidden at picker levels — without this the strip
  # would change with no visible reason.
  assert_eq "zz" "$(printf '%s' "$out" | jq -r '.filterText')"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.filterHidden')"
}

test_theme_previews_are_not_confused_with_background_previews() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Both picker levels cache previews by name, so the caches must be keyed by
  # kind as well — the host echoes the kind back with every push precisely so
  # a theme and a wallpaper sharing a name cannot share a thumbnail. Here the
  # host answers the Theme level's request with a bg-kinded push for the same
  # name: the theme item must still be showing its placeholder.
  local data='{"theme":{"current":"nord","options":["nord"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-misdelivered-preview")
  assert_eq 1 "$(printf '%s' "$out" | jq '.strip.count')"
  assert_eq 0 "$(printf '%s' "$out" | jq '.strip.withImages')" \
    "a preview pushed under the wrong kind must never be rendered into the Theme coverflow"
  # ...and the correctly-kinded push right after it must land, so this is
  # proving the cache is KEYED by kind, not that pushes are being dropped.
  assert_eq 1 "$(printf '%s' "$out" | jq '.strip.withImagesAfterCorrectPush')" \
    "a correctly-kinded push must still reach the Theme coverflow"
}

run_tests

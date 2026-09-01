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
  assert_contains "$js" '"previews"'
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

test_previews_are_requested_once_per_level_not_once_per_item() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Three renders of the Background level, no thumbnail ever supplied by the
  # host in between (omamacSetPreview is never called). The page must ask ONCE
  # for the whole level and never again: the host gets a single hs.task per
  # level (it loses the stdout of most of its children when a couple of dozen
  # run at once), so a per-item or per-render request is not something it can
  # serve. Without the guard this is a fresh batch on every keystroke, each
  # respawning sips for every item in the level.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["a.jpg","b.jpg","c.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-render-thrice")
  local previews; previews=$(printf '%s' "$out" | jq -c '[.[] | select(.action == "previews")]')
  assert_eq 1 "$(printf '%s' "$previews" | jq 'length')" \
    "the level must be requested exactly once across 3 renders of 3 items"
  assert_eq '{"action":"previews","kind":"bg"}' "$(printf '%s' "$previews" | jq -c '.[0]')"
  # And emphatically NOT a message per item.
  assert_eq 0 "$(printf '%s' "$out" | jq '[.[] | select(.action == "preview")] | length')" \
    "there must be no per-item preview requests left at all"
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
  local previews; previews=$(printf '%s' "$out" | jq -c '[.[] | select(.action == "previews")]')
  assert_eq '[{"action":"previews","kind":"bg"}]' "$previews" \
    "entering Background must request the level's previews once, as kind=bg"
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

test_an_unavailable_preview_leaves_the_placeholder_and_asks_no_more() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # A single Background item whose thumbnail the host could not read. An empty
  # uri must never be cached — `img.src = ""` renders as a broken image, and
  # the bordered placeholder is the right thing to keep showing. It must also
  # not provoke another batch: omamac already tried, inside the one task the
  # host gets for the level.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":["only.jpg"]},"colors":{}}'
  local out; out=$(run_driver "$data" "bg-unavailable-preview")
  assert_eq 1 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "previews")] | length')" \
    "an unavailable preview must not trigger another request for the level"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.hasImg')" \
    "an empty preview must never be cached/rendered as a broken <img>; the placeholder must remain"
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

test_theme_level_requests_its_previews_with_the_theme_kind() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"nord","options":["gruvbox","nord","rose-pine"]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "theme-open-and-report")
  # The kind is what the host routes on: kind=theme becomes
  # `omamac preview --paths --theme`, which reads the vendored theme list and
  # fetches each theme's preview shot. With the wrong kind it would instead
  # list the CURRENT theme's wallpapers and nothing would match.
  local previews; previews=$(printf '%s' "$out" | jq -c '[.messages[] | select(.action == "previews")]')
  assert_eq '[{"action":"previews","kind":"theme"}]' "$previews" \
    "the Theme level must make exactly one previews request, as kind=theme"
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

# ---------------------------------------------------------------------------
# The Font level.
#
# Unlike Theme and Background — which upstream launches as the image picker
# via an `action:` — Font is a menu PROVIDER, so it stays a list of rows in
# the card. omarchy-menu.jsonc:
#
#   "style.font": {"icon":"\ue659","label":"Font","provider":"fonts"}
#
# and Menu.qml builds each row as
#
#   icon: (value === current) ? "\u2713" : (spec.icon || "")
#
# with the fonts provider's own icon also being \ue659. So every font row
# carries a glyph, and the ACTIVE font's row shows a check in place of it.
# Note this is not the `checked:` mechanism, which appends " \u2713" to a
# static entry's label instead — provider rows put the marker in the icon
# column. And every label renders in the menu's own font (`root.fontFamily`
# throughout Menu.qml), never in the typeface it names.
# ---------------------------------------------------------------------------

test_font_rows_carry_the_provider_glyph_and_mark_the_current_one() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Andale Mono","Menlo","Monaco"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "font-open-and-report")

  assert_eq "false" "$(printf '%s' "$out" | jq -r '.cardHidden')" "Font is a card list, not a coverflow"
  assert_eq "true"  "$(printf '%s' "$out" | jq -r '.cvHidden')"
  assert_eq 3 "$(printf '%s' "$out" | jq '.list | length')"

  # The active font is marked with a check IN THE ICON COLUMN...
  # jq -a escapes non-ASCII, so no PUA literal has to survive in this file —
  # the codebase has already had glyphs silently blanked by being typed raw.
  assert_eq '"\u2713"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "Menlo") | .icon')" \
    "the current font's row must show the check marker"
  # ...and its LABEL must stay clean: upstream only appends " \u2713" to a
  # label for static `checked:` entries, never for provider rows.
  assert_eq "Menlo" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')" \
    "the label must not have the marker appended to it"

  # Every other row carries the fonts provider glyph, not an empty column.
  assert_eq '"\ue659"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "Andale Mono") | .icon')"
  assert_eq '"\ue659"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "Monaco") | .icon')"
  assert_eq 0 "$(printf '%s' "$out" | jq '[.list[] | select(.icon == "")] | length')" \
    "no font row may have an empty icon column"

  # And the level opens on the current font, the way every level now does.
  assert_eq "Menlo" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')"
}

test_root_rows_keep_their_own_icons() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Regression guard for the change above: the per-level icon function must not
  # cost the root level its three glyphs (U+F0E0C, U+E659, U+F03E, verbatim
  # from omarchy-menu.jsonc).
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "root-report")
  assert_eq '["\udb83\ude0c","\ue659","\uf03e"]' "$(printf '%s' "$out" | jq -a -c '[.list[] | .icon]')" \
    "root must keep the Theme/Font/Background glyphs from omarchy-menu.jsonc"
}

# The Font menu is WIDER than every other card. Menu.qml:111 special-cases
# exactly two menus —
#
#   (activeMenu === "trigger.capture.screenrecord" || activeMenu === "style.font")
#     ? Style.space(520) : Style.space(300)
#
# — and font family names are long enough that at 300px most of them ellipsis
# away ("CaskaydiaMono Nerd\u2026", "JetBrainsMono Nerd\u2026"), which is
# exactly what a font list must not do.
test_font_menu_is_wider_than_the_other_card_levels() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Andale Mono","Menlo","Monaco"]},"bg":{"current":"","options":[]},"colors":{}}'
  assert_eq "520px" "$(run_driver "$data" "font-open-and-report" | jq -r '.cardWidth')" \
    "the Font level must use Omarchy's wider card, or long family names ellipsis away"
  assert_eq "300px" "$(run_driver "$data" "root-report" | jq -r '.cardWidth')" \
    "every other card level keeps the standard width"
}

run_tests

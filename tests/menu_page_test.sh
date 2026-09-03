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
  assert_eq '["\udb83\ude0c","\ue659","\uf03e","\uf00a"]' "$(printf '%s' "$out" | jq -a -c '[.list[] | .icon]')" \
    "root keeps what is not app-specific: Theme, Font, Background, Applications"
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

# The Font list: no scrollbar, roomier rows, larger names.
#
# The scrollbar's absence is upstream — Menu.qml contains no ScrollBar at all.
# What it does instead is size the list to end PART-WAY THROUGH the first
# hidden row (rowPeek, 55% of a row): "a clipped row is what tells the eye
# there is more below the fold, so never come out even on a row boundary"
# (foldedListHeight).
#
# The row height, gap and label size on this level are NOT upstream: those are
# 50 / 3 / 16 there (Menu.qml baseRowHeight, Style.spacing.xs,
# Style.font.heading) and remain so on every other card level. Pedro asked for
# more room and bigger names on the font list specifically.

test_font_rows_are_roomier_and_larger_than_the_default_level() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Andale Mono","Menlo","Monaco"]},"bg":{"current":"","options":[]},"colors":{}}'
  local font root
  font=$(run_driver "$data" "font-open-and-report")
  root=$(run_driver "$data" "root-report")

  assert_eq "19px" "$(printf '%s' "$font" | jq -r '.nameSize')" "font names must be larger"
  assert_eq "60px" "$(printf '%s' "$font" | jq -r '.rowH')"     "font rows must be taller"
  assert_eq "6px"  "$(printf '%s' "$font" | jq -r '.rowGap')"   "font rows must be further apart"

  # ...and every other card level keeps Omarchy's numbers exactly.
  assert_eq "16px" "$(printf '%s' "$root" | jq -r '.nameSize')" "root keeps Style.font.heading"
  assert_eq "50px" "$(printf '%s' "$root" | jq -r '.rowH')"     "root keeps baseRowHeight"
  assert_eq "3px"  "$(printf '%s' "$root" | jq -r '.rowGap')"   "root keeps Style.spacing.xs"
}

# Guarded here as source text because a DOM shim has no layout engine and
# cannot see it: #list is a flex column, so without flex-shrink:0 the rows
# compress to fit its max-height rather than overflowing. Measured in a real
# WKWebView that was 25px against a declared 60px — which also silently
# defeats the mid-row fold, since a list that never overflows is never
# clipped. Verified live offscreen after the fix.
test_rows_do_not_shrink_to_fit_the_list() {
  local css; css=$(sed -n '/<style>/,/<\/style>/p' "$PAGE")
  case "$css" in
    *"flex: 0 0 auto"*) ;;
    *) fail "rows must not be flex-shrinkable, or the row height and the fold both stop meaning anything" ;;
  esac
}

test_the_list_hides_its_scrollbar() {
  local css; css=$(sed -n '/<style>/,/<\/style>/p' "$PAGE")
  # Both spellings are needed: WebKit paints an overlay scrollbar that only
  # the pseudo-element suppresses, and scrollbar-width is the standard one.
  assert_contains "$css" "#list::-webkit-scrollbar"
  assert_contains "$css" "scrollbar-width: none"
}

test_an_overflowing_list_ends_mid_row_instead_of_scrolling() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # 40 fonts at 60+6 per row is far more than 70% of a 1080px viewport can
  # hold, so the list must fold. Row step 66, peek round(60*0.55) = 33.
  # available = round(1080*0.7) - (18*2 + 34 + 6) = 756 - 76 = 680.
  # full = floor((680 - 33) / 66) = 9  ->  9*66 + 33 = 627.
  local opts; opts=$(python3 -c "import json;print(json.dumps(['Font %02d' % i for i in range(40)]))")
  local data; data=$(printf '{"theme":{"current":"","options":[]},"font":{"current":"Font 00","options":%s},"bg":{"current":"","options":[]},"colors":{}}' "$opts")
  local out; out=$(OMAMAC_VIEWPORT_H=1080 run_driver "$data" "font-open-and-report")
  local maxh; maxh=$(printf '%s' "$out" | jq -r '.listMaxH')
  assert_eq "627px" "$maxh" "the folded height must be whole rows plus a 55% peek"

  # The property that actually matters, stated independently of the arithmetic:
  # the fold must NOT land on a row boundary, or the cut row disappears and
  # with it the only cue that there is more below.
  local n="${maxh%px}"
  [ $(( (n + 6) % 66 )) -ne 0 ] || \
    fail "the list ended exactly on a row boundary — nothing tells the eye there is more below the fold"
}

test_a_short_list_is_not_folded_at_all() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # 3 rows: 3*60 + 2*6 = 192, well inside the budget, so no peek is added and
  # the card ends flush with the last row.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Andale Mono","Menlo","Monaco"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(OMAMAC_VIEWPORT_H=1080 run_driver "$data" "font-open-and-report")
  assert_eq "192px" "$(printf '%s' "$out" | jq -r '.listMaxH')" \
    "a list that fits must end flush with its last row, with no peek"
}

# The Size level. Ghostty points shown exactly as written to the config — not
# Omarchy's px scale, which only exists there because one knob also drives the
# Quickshell rem root and GTK's text-scaling-factor. Neither exists on macOS,
# so showing "12" and writing 9 would just misreport the chosen number.
test_size_level_marks_the_current_size_and_applies_the_selected_one() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["14","15","16","17"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "size-open-and-report")

  assert_eq "false" "$(printf '%s' "$out" | jq -r '.cardHidden')" "Size is a card list, not a coverflow"
  assert_eq 4 "$(printf '%s' "$out" | jq '.list | length')"
  # Opens ON the size in effect (index 2 of four), like every other level.
  assert_eq "16" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')"
  assert_eq '"\u2713"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "16") | .icon')" \
    "the active size must carry the check marker"
  assert_eq '"\uf034"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "14") | .icon')" \
    "every other row carries the Size glyph"
  # A picker level must never request image previews.
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "previews")] | length')"
}

test_size_enter_applies_via_the_font_size_command() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Opens on 16 (index 2), ArrowDown moves to 17, Enter applies it. Asserting
  # action, cmd AND arg on the same message is what makes a wrong command name
  # — `font` instead of `font-size`, which would try to set a FONT FAMILY
  # called "17" — impossible to slip through.
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["14","15","16","17"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "size-select-apply")
  assert_eq '{"action":"apply","cmd":"font-size","arg":"17"}' "$(printf '%s' "$out" | jq -c '.[-1]')"
}


# Ghostty's per-application settings live together under Applications >
# Ghostty. The font FAMILY deliberately does not: it is system-wide, shared by
# any app added later, so it stays at the root. Omarchy nests the same way wherever a settings group has more than one
# knob (style.bar -> Position -> Top/Bottom).
test_ghostty_groups_its_settings_together() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Menlo"]},"fontSize":{"current":"16","options":["16"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "ghostty-menu-report")
  # Ghostty's PER-APP settings. The font family is not one of them: it is a
  # system-wide choice that an editor added later shares, so it lives at the
  # root — the same shape omarchy-menu.jsonc gives style.font.
  assert_eq '["Size","Opacity"]' "$(printf '%s' "$out" | jq -c '[.list[] | .name]')"
  # Entering Font must NOT apply anything — it is a submenu, and a stray
  # apply here would try to set a font family literally called "Family".
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "apply")] | length')" \
    "opening the Ghostty submenu must not apply anything"
  # Neither row is a picker level, so no previews may be requested either.
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "previews")] | length')"
}

# Escape used to jump straight to the root, which only worked while the menu
# was exactly two deep. It must now walk up ONE level, landing on the row that
# was drilled into.
test_escape_walks_up_one_level_and_keeps_its_place() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"Menlo","options":["Menlo"]},"fontSize":{"current":"16","options":["14","16"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "size-then-escape")
  # Back at Font, not at the root...
  assert_eq '["Size","Opacity"]' "$(printf '%s' "$out" | jq -c '[.list[] | .name]')" \
    "Escape from Size must land on Ghostty, not jump to the root"
  # ...with Size still highlighted, so the way back in is where you left it.
  assert_eq "Size" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')"
  # And it must not have closed the menu.
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "close")] | length')"
}

# Opacity is shown as a percentage but the CLI takes a bare integer, so the
# level has to strip the suffix on the way out. Sending "85%" would be refused
# by omamac-opacity as non-numeric, and the menu would look like it did nothing.
test_opacity_applies_a_bare_number_not_the_displayed_percentage() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"90","options":["85","90","95","100"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "opacity-select-apply")
  # Opens on 90 (index 1), ArrowDown moves to 95.
  assert_eq '{"action":"apply","cmd":"opacity","arg":"95"}' "$(printf '%s' "$out" | jq -c '.[-1]')"
}

test_opacity_level_shows_percentages_and_marks_the_current_one() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"90","options":["85","90","95","100"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "opacity-open-and-report")
  assert_eq '["85%","90%","95%","100%"]' "$(printf '%s' "$out" | jq -c '[.list[] | .name]')"
  assert_eq "90%" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')" \
    "the level must open on the opacity in effect"
  assert_eq '"\u2713"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "90%") | .icon')"
}


# Slack is a row that RUNS something rather than opening a level: it copies the
# sidebar theme string, because Slack itself cannot be driven (no theme deep
# link, and its only local store is a locked Electron leveldb caching an
# account-level setting).
# Applications groups the apps omamac cannot drive automatically, so more can
# be added beside Slack without cluttering the root.
test_applications_is_a_section_not_an_action() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"100","options":["100"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "apps-report")
  assert_eq '["AeroSpace","Ghostty","Slack"]' "$(printf '%s' "$out" | jq -c '[.list[] | .name]')"
  assert_eq '"\uf198"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "Slack") | .icon')" \
    "each application keeps its own glyph, not the section's"
  # Opening the section must not run anything.
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "apply")] | length')" \
    "opening Applications must not apply anything"
}

test_escape_from_applications_returns_to_root_on_that_row() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"100","options":["100"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "apps-then-escape")
  assert_eq "Applications" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')" \
    "Escape must land back on the row that was drilled into"
  assert_eq 0 "$(printf '%s' "$out" | jq '[.messages[] | select(.action == "close")] | length')" \
    "Escape from a section must not close the menu"
}

test_slack_row_runs_the_copy_instead_of_drilling_in() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"100","options":["100"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "slack-copy")
  assert_eq '{"action":"apply","cmd":"slack","arg":"--copy"}' "$(printf '%s' "$out" | jq -c '.[-1]')"
}

# AeroSpace's gaps: its CLI cannot set them and its config has no include, so
# omamac renders the whole config from a template. The menu just picks a number.
test_gaps_applies_through_the_aerospace_command() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local data='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"100","options":["100"]},"gaps":{"current":"10","options":["8","10","12"]},"bg":{"current":"","options":[]},"colors":{}}'
  local out; out=$(run_driver "$data" "gaps-select-apply")
  # Opens on the gap in effect (10, index 1) and applies it.
  assert_eq '{"action":"apply","cmd":"aerospace","arg":"10"}' "$(printf '%s' "$out" | jq -c '.[-1]')"
}

# Assigning a workspace to a monitor is a two-part choice, so the monitor level
# has to know which workspace row was drilled in from. That context is read
# from the row's LABEL rather than its position, because filtering reorders
# what the selection indexes into.
WS_DATA='{"theme":{"current":"","options":[]},"font":{"current":"","options":[]},"fontSize":{"current":"16","options":["16"]},"opacity":{"current":"100","options":["100"]},"gaps":{"current":"10","options":["10"]},"workspaces":{"list":[{"id":"1","monitor":"main"},{"id":"2","monitor":"secondary"},{"id":"3","monitor":"main"}],"monitors":["main","secondary","DELL P2723DE"]},"bg":{"current":"","options":[]},"colors":{}}'

test_workspaces_level_shows_each_workspace_with_its_monitor() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local out; out=$(run_driver "$WS_DATA" "workspaces-report")
  assert_eq 3 "$(printf '%s' "$out" | jq '.list | length')"
  assert_contains "$(printf '%s' "$out" | jq -r '.list[1].name')" "2"
  assert_contains "$(printf '%s' "$out" | jq -r '.list[1].name')" "secondary" \
    "each row must show the monitor that workspace is pinned to"
}

test_monitor_level_checks_the_monitor_of_the_workspace_drilled_into() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Workspace 2 is on `secondary`, so THAT is the row that opens selected and
  # carries the check — not workspace 1's `main`.
  local out; out=$(run_driver "$WS_DATA" "wsmonitor-report")
  assert_eq '["main","secondary","DELL P2723DE"]' "$(printf '%s' "$out" | jq -c '[.list[] | .name]')"
  assert_eq "secondary" "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')" \
    "the monitor list must open on the drilled-into workspace's own monitor"
  assert_eq '"\u2713"' "$(printf '%s' "$out" | jq -a -c '.list[] | select(.name == "secondary") | .icon')"
}

test_assigning_sends_the_workspace_and_the_monitor_together() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  # Workspace 2 opens on `secondary` (index 1); ArrowDown moves to DELL.
  # Both halves must travel: a message carrying only the monitor would
  # reassign whichever workspace omamac happened to guess.
  local out; out=$(run_driver "$WS_DATA" "wsmonitor-apply")
  assert_eq '{"action":"apply","cmd":"aerospace","args":["--workspace","2=DELL P2723DE"]}' \
    "$(printf '%s' "$out" | jq -c '.[-1]')"
}

test_escape_from_a_monitor_list_returns_to_its_workspace_row() {
  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to drive menu.html — cannot verify the page"
    return
  fi
  local out; out=$(run_driver "$WS_DATA" "wsmonitor-escape")
  assert_contains "$(printf '%s' "$out" | jq -r '.list[] | select(.on) | .name')" "2" \
    "Escape must land back on the workspace that was drilled into, not the first row"
}

run_tests

#!/usr/bin/env bash
# The region picker's geometry, under a plain Lua interpreter — no Hammerspoon,
# no screen, no mouse. Only the pure parts can be reached this way; the canvas,
# the freeze and the event taps are verified live against the running app.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

REGION="$OMAMAC_ROOT/hammerspoon/region.lua"

# Runs a Lua snippet with the module loaded as `R`, printing whatever it does.
# The module must LOAD without Hammerspoon for this to work at all — which is
# itself worth guarding: a stray top-level hs.* call would break the host at
# require time, not at first use.
region_lua() {
  local script="$TMPDIR_TEST/region_case.lua"
  { printf 'local R = dofile("%s")\n' "$REGION"; cat; } > "$script"
  # 2>&1 because the only Lua front-end here is `nvim --headless`, whose print
  # goes to stderr. Every other Lua test in this suite captures the same way.
  lua_run "$script" 2>&1
}

test_module_loads_without_hammerspoon() {
  local out rc
  out=$(region_lua <<'LUA'
print(type(R.pick) == "function" and "ok" or "missing")
LUA
)
  rc=$?
  [ "$rc" -ne 127 ] || { fail "no Lua interpreter available to load region.lua"; return; }
  assert_eq "ok" "$out" "region.lua must load with no hs.* available at top level"
}

test_geometry_is_spelled_the_way_slurp_spells_it() {
  # "X,Y WxH" — upstream's format, and what bin/omamac-capture parses. A space
  # where the comma goes, or the other way round, and the capture is refused.
  assert_eq "12,34 560x480" "$(region_lua <<'LUA'
print(R._rectString({x = 12, y = 34, w = 560, h = 480}))
LUA
)" "geometry must be slurp's X,Y WxH"
}

test_negative_origins_survive_the_round_trip() {
  assert_eq "-1920,-200 800x600" "$(region_lua <<'LUA'
print(R._rectString({x = -1920, y = -200, w = 800, h = 600}))
LUA
)" "a monitor left of the main one has a negative origin"
}

# Upstream: slurp "highlights the smallest box containing the point and keeps
# the first one on a tie". That is what makes a window win over the monitor
# behind it — without it every click resolves to the whole screen.
test_the_smallest_rectangle_containing_the_point_wins() {
  assert_eq "100,100 200x200" "$(region_lua <<'LUA'
local rects = {
  {x = 0,   y = 0,   w = 2560, h = 1440},  -- the monitor
  {x = 100, y = 100, w = 200,  h = 200},   -- a window on it
}
print(R._rectString(R._rectAt(rects, 150, 150)))
LUA
)" "a window must win over the monitor containing it"
}

test_a_tie_keeps_the_first_candidate() {
  # Windows come before monitors in the candidate list, and two rects of equal
  # area must resolve to the earlier one — otherwise which window you get
  # depends on table order, which is to say on nothing.
  assert_eq "0,0 100x100" "$(region_lua <<'LUA'
local rects = { {x = 0, y = 0, w = 100, h = 100}, {x = 0, y = 0, w = 100, h = 100} }
local r = R._rectAt(rects, 10, 10)
print(R._rectString(r))
LUA
)" "equal areas must resolve to the first candidate"
}

test_a_point_outside_every_rectangle_resolves_to_nothing() {
  assert_eq "nil" "$(region_lua <<'LUA'
local rects = { {x = 0, y = 0, w = 10, h = 10} }
print(tostring(R._rectAt(rects, 500, 500)))
LUA
)" "a point in no rectangle must not silently pick one"
}

# Half-open on the far edge: a rect at x=0 w=10 owns 0..9, not 10. Without this
# two adjacent windows both claim the pixel on their shared border.
test_rectangles_are_half_open_at_the_far_edge() {
  assert_eq "inside=true edge=false" "$(region_lua <<'LUA'
local rects = { {x = 0, y = 0, w = 10, h = 10} }
print(string.format("inside=%s edge=%s",
  tostring(R._rectAt(rects, 9, 9) ~= nil),
  tostring(R._rectAt(rects, 10, 10) ~= nil)))
LUA
)" "the far edge belongs to the next rectangle"
}

# Dragging up-and-left is as ordinary as dragging down-and-right, and must
# select what it looks like it selects rather than a zero-size rect.
test_a_drag_in_any_direction_yields_the_same_rectangle() {
  assert_eq "100,100 50x40|100,100 50x40" "$(region_lua <<'LUA'
local a = R._rectString(R._dragRect({x = 100, y = 100}, {x = 150, y = 140}))
local b = R._rectString(R._dragRect({x = 150, y = 140}, {x = 100, y = 100}))
print(a .. "|" .. b)
LUA
)" "a backwards drag must give the same rectangle as a forwards one"
}

# Upstream's rule, verbatim: "a bare click (area < 20px^2) snaps to the
# rectangle it landed in, so users don't end up with accidental 2px captures".
test_the_click_threshold_is_omarchys() {
  assert_eq "20" "$(region_lua <<'LUA'
print(R._CLICK_AREA)
LUA
)" "the bare-click threshold must be Omarchy's 20"
}

test_a_bare_click_is_below_the_threshold_and_a_real_drag_is_not() {
  assert_eq "click=true drag=false" "$(region_lua <<'LUA'
local click = R._dragRect({x = 10, y = 10}, {x = 12, y = 12})   -- 2x2 = 4
local drag  = R._dragRect({x = 10, y = 10}, {x = 40, y = 40})   -- 30x30 = 900
print(string.format("click=%s drag=%s",
  tostring(click.w * click.h < R._CLICK_AREA),
  tostring(drag.w * drag.h < R._CLICK_AREA)))
LUA
)" "a 2x2 twitch is a click; a 30x30 drag is a selection"
}

run_tests

-- omamac region picker — a port of omarchy-capture-region.
--
-- Upstream freezes the screen with `hyprpicker -r -z`, runs slurp over it, and
-- prints the picked rectangle as "X,Y WxH". macOS has neither, so this rebuilds
-- both out of hs.canvas: one canvas per screen holding a screenshot (the
-- freeze), a second holding the dim and the selection (slurp).
--
-- The two layers are separate for the reason upstream separates them. slurp
-- exits before grim runs, so grim shoots the UNDIMMED frozen screen; if the
-- dimming were part of the same surface, every screenshot would come out dark.
-- So `keepFreeze` tears down the overlay and leaves the freeze standing, and
-- the caller drops it once it has captured.
--
-- Geometry is emitted in slurp's own "X,Y WxH", and in the global coordinate
-- space with the main screen's top-left at 0,0 — measured to be exactly the
-- space `screencapture -R` takes, so nothing transforms it on the way.

local M = {}

local SCREENCAPTURE = "/usr/sbin/screencapture"

-- Upstream: "a bare click (area < 20px^2) snaps to the rectangle it landed in,
-- so users don't end up with accidental 2px captures".
local CLICK_AREA = 20

local ESCAPE_KEYCODE = 53

-- Live picker state. Module-level rather than closed over: an hs.eventtap or
-- hs.canvas that nothing references is garbage collected and silently stops
-- working, which is the failure mode that leaves a frozen screen on screen with
-- no way to dismiss it.
local S = nil

local function rectString(r)
  return string.format("%d,%d %dx%d", r.x, r.y, r.w, r.h)
end

local function contains(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Upstream resolve_rect_at: the SMALLEST rectangle containing the point, first
-- one kept on a tie. That is what makes a floating window win over the tiled
-- one behind it, and the window win over its monitor.
local function rectAt(rects, x, y)
  local best, bestArea = nil, nil
  for _, r in ipairs(rects) do
    if contains(r, x, y) then
      local area = r.w * r.h
      if not bestArea or area < bestArea then
        best, bestArea = r, area
      end
    end
  end
  return best
end

local function screenRects()
  local out = {}
  for _, scr in ipairs(hs.screen.allScreens()) do
    local f = scr:fullFrame()
    out[#out + 1] = { x = f.x, y = f.y, w = f.w, h = f.h }
  end
  return out
end

-- Upstream feeds slurp monitor rects as well as window rects, so a cursor in a
-- gap or over the bar highlights the monitor rather than nothing. Windows come
-- first so that, at equal area, the window wins.
local function windowRects()
  local out, seen = {}, {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    local app = w:application()
    -- Our own freeze and overlay are windows too; hinting them would offer the
    -- picker's own surface as a capture target.
    if w:isStandard() and w:isVisible() and (not app or app:name() ~= "Hammerspoon") then
      local f = w:frame()
      local r = { x = math.floor(f.x), y = math.floor(f.y), w = math.floor(f.w), h = math.floor(f.h) }
      local key = rectString(r)
      -- Windows stacked at identical geometry collapse to one rectangle:
      -- duplicates cannot be told apart and only add ties to resolve.
      if r.w > 0 and r.h > 0 and not seen[key] then
        seen[key] = true
        out[#out + 1] = r
      end
    end
  end
  return out
end

local function candidates(mode)
  if mode == "region" then return {} end
  local rects = windowRects()
  for _, r in ipairs(screenRects()) do rects[#rects + 1] = r end
  return rects
end

-- Normalises a drag into a positive-extent rectangle, so dragging up-and-left
-- selects what it looks like it selects rather than a zero-size rect.
local function dragRect(a, b)
  local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
  local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
  return { x = math.floor(x1), y = math.floor(y1), w = math.floor(x2 - x1), h = math.floor(y2 - y1) }
end

local function teardownOverlay()
  if not S then return end
  for _, c in ipairs(S.overlays) do c:delete() end
  S.overlays = {}
  if S.taps then
    for _, t in ipairs(S.taps) do t:stop() end
    S.taps = nil
  end
end

local function teardownFreeze()
  if not S then return end
  for _, c in ipairs(S.freezes) do c:delete() end
  S.freezes = {}
  for _, p in ipairs(S.shots) do os.remove(p) end
  S.shots = {}
end

local function finish(rect)
  local st = S
  if not st then return end
  teardownOverlay()
  local drop = function() teardownFreeze(); S = nil end
  if not (st.keepFreeze and rect) then
    teardownFreeze()
    S = nil
    drop = function() end
  end
  -- The callback runs AFTER the overlay is gone, so a caller that captures
  -- immediately never catches the dimming.
  st.callback(rect and rectString(rect) or nil, drop)
end

-- Redraws the overlay: the dim, plus either the hinted rectangle under the
-- cursor or the rectangle being dragged. Canvas elements are canvas-relative,
-- so each screen's overlay subtracts its own origin; parts of a selection that
-- fall on another screen are clipped by that canvas rather than needing to be
-- split.
local function paint()
  if not S then return end
  local sel = S.dragging and dragRect(S.origin, S.cursor) or S.hint
  for i, c in ipairs(S.overlays) do
    local f = S.frames[i]
    if sel then
      local local_ = { x = sel.x - f.x, y = sel.y - f.y, w = sel.w, h = sel.h }
      c[2].frame = local_
      c[2].action = "fill"
      c[3].frame = local_
      c[3].action = "stroke"
      -- The readout sits just under the selection, and is dropped when the
      -- selection is too small to hold it rather than overflowing it.
      c[4].frame = { x = local_.x, y = local_.y + local_.h + 4, w = math.max(local_.w, 90), h = 18 }
      c[4].text = string.format("%d × %d", sel.w, sel.h)
      c[4].action = (sel.w > 40 and sel.h > 20) and "fill" or "skip"
    else
      c[2].action = "skip"
      c[3].action = "skip"
      c[4].action = "skip"
    end
  end
end

local function onMouse(e)
  if not S then return false end
  local t = e:getType()
  -- The event's OWN location, not hs.mouse.absolutePosition(). Polling the
  -- cursor answers "where is the pointer now", which for a fast drag is
  -- somewhere past where the event happened — and for a synthesised event may
  -- be nowhere near it at all.
  local p = e:location() or hs.mouse.absolutePosition()
  S.cursor = { x = p.x, y = p.y }

  if t == hs.eventtap.event.types.leftMouseDown then
    S.dragging = true
    S.origin = { x = p.x, y = p.y }
  elseif t == hs.eventtap.event.types.leftMouseUp then
    S.dragging = false
    local r = dragRect(S.origin, S.cursor)
    -- Upstream's rule: a bare click snaps to whatever rectangle it landed in.
    if r.w * r.h < CLICK_AREA then
      r = rectAt(S.rects, S.origin.x, S.origin.y)
    end
    if r and r.w > 0 and r.h > 0 then finish(r) else finish(nil) end
    return true
  else
    if not S.dragging then
      S.hint = rectAt(S.rects, p.x, p.y)
    end
  end
  paint()
  return true
end

local function onKey(e)
  if not S then return false end
  if e:getKeyCode() == ESCAPE_KEYCODE then
    finish(nil)
    return true
  end
  return true
end

local function show(mode)
  local rects = candidates(mode)
  S.rects = rects
  S.frames = {}
  S.overlays = {}

  for i, scr in ipairs(hs.screen.allScreens()) do
    local f = scr:fullFrame()
    S.frames[i] = f

    -- The frozen screenshot. scaleToFit, not a 1:1 blit: on a Retina display
    -- screencapture hands back twice as many pixels as the frame has points.
    local freeze = hs.canvas.new(f)
    freeze:appendElements({
      type = "image",
      image = hs.image.imageFromPath(S.shots[i]),
      imageScaling = "scaleToFit",
      frame = { x = 0, y = 0, w = f.w, h = f.h },
    })
    freeze:level(hs.drawing.windowLevels.screenSaver)
    freeze:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    freeze:show()
    S.freezes[#S.freezes + 1] = freeze

    local overlay = hs.canvas.new(f)
    overlay:appendElements(
      { -- 1: the dim, over the whole screen
        type = "rectangle",
        action = "fill",
        fillColor = { red = 0, green = 0, blue = 0, alpha = 0.45 },
        frame = { x = 0, y = 0, w = f.w, h = f.h },
      },
      { -- 2: punches the selection out of the dim, so the frozen screen shows
        -- through it at full brightness. `clear` erases what is already on the
        -- canvas rather than painting over it — a transparent fill would draw
        -- nothing at all and leave the dim intact.
        type = "rectangle",
        action = "fill",
        fillColor = { white = 1, alpha = 1 },
        compositeRule = "clear",
        frame = { x = 0, y = 0, w = 0, h = 0 },
      },
      { -- 3: the selection's border, drawn after the hole so it is not erased
        type = "rectangle",
        action = "skip",
        strokeColor = S.stroke,
        strokeWidth = 2,
        frame = { x = 0, y = 0, w = 0, h = 0 },
      },
      { -- 4: the size readout
        type = "text",
        action = "skip",
        text = "",
        textColor = S.stroke,
        textSize = 13,
        textAlignment = "left",
        frame = { x = 0, y = 0, w = 0, h = 0 },
      }
    )
    overlay:level(hs.drawing.windowLevels.screenSaver + 1)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    overlay:show()
    S.overlays[#S.overlays + 1] = overlay
  end

  local et = hs.eventtap.event.types
  S.taps = {
    hs.eventtap.new({ et.mouseMoved, et.leftMouseDown, et.leftMouseDragged, et.leftMouseUp }, onMouse),
    hs.eventtap.new({ et.keyDown }, onKey),
  }
  for _, t in ipairs(S.taps) do t:start() end

  S.hint = rectAt(rects, S.cursor.x, S.cursor.y)
  paint()
end

-- pick(mode, opts, callback)
--
--   mode      "smart"      freeform, with window/monitor rects hinted; a bare
--                          click snaps to the rectangle it landed in
--             "region"     freeform only, nothing hinted
--             "windows"    snap to a window or monitor
--             "fullscreen" the screen under the cursor, no interaction
--   opts      { keepFreeze = true, stroke = <hs.drawing colour> }
--   callback  (geometry|nil, dropFreeze)
--
-- Calling it while a pick is in progress cancels that one, the way invoking
-- upstream's screenshot again does (`pkill slurp && exit 0`).
function M.pick(mode, opts, callback)
  if S then finish(nil); return end
  mode = mode or "smart"
  opts = opts or {}

  local p = hs.mouse.absolutePosition()

  if mode == "fullscreen" then
    local f = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
    callback(rectString({ x = f.x, y = f.y, w = f.w, h = f.h }), function() end)
    return
  end

  S = {
    mode = mode,
    keepFreeze = opts.keepFreeze or false,
    stroke = opts.stroke or { white = 1, alpha = 0.9 },
    callback = callback,
    cursor = { x = p.x, y = p.y },
    origin = { x = p.x, y = p.y },
    dragging = false,
    freezes = {},
    overlays = {},
    shots = {},
    taps = nil,
  }

  -- Freeze every screen first, and only then show anything: a canvas raised
  -- before the last screenshot is taken ends up inside it.
  --
  -- -R with each screen's own frame rather than -D <n>: the display indices
  -- screencapture uses are not documented to match hs.screen's order, while the
  -- rectangle space is measured to be identical. One fewer thing to be wrong.
  local screens = hs.screen.allScreens()
  local pending = #screens
  if pending == 0 then S = nil; callback(nil, function() end); return end

  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  for i, scr in ipairs(screens) do
    local f = scr:fullFrame()
    -- Not os.tmpname()..".png": tmpname CREATES the file it names, so appending
    -- an extension leaves that empty original behind on every pick. These are
    -- cleaned up by teardownFreeze.
    local path = string.format("%s/omamac-freeze-%d-%d.png", dir, hs.processInfo.processID, i)
    S.shots[i] = path
    local rect = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
    -- Kept in S so the task is referenced until it exits.
    S["task" .. i] = hs.task.new(SCREENCAPTURE, function()
      pending = pending - 1
      if pending == 0 and S then show(mode) end
    end, { "-x", "-o", "-R", rect, path })
    S["task" .. i]:start()
  end
end

function M.cancel()
  if S then finish(nil) end
end

function M.active() return S ~= nil end

-- Test seam. These three are the whole of the picker's geometry — which
-- rectangle a click resolves to, how a drag becomes a rectangle, and how a
-- rectangle is spelled — and they are pure, so they can be checked under a
-- plain Lua interpreter with no Hammerspoon and no screen. Everything else
-- here needs a running WKWebView and a mouse, and is verified live instead.
M._rectAt = rectAt
M._dragRect = dragRect
M._rectString = rectString
M._CLICK_AREA = CLICK_AREA

return M

-- omamac pickers — a port of omarchy-capture-region, plus the colour picker
-- Omarchy gets from hyprpicker.
--
-- Upstream freezes the screen with `hyprpicker -r -z`, runs slurp over it, and
-- prints the picked rectangle as "X,Y WxH". macOS has neither, so this rebuilds
-- both out of hs.canvas: one canvas per screen holding a screenshot (the
-- freeze), a second holding whatever the mode draws on top.
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

-- The readout that follows the cursor, in points.
--
-- There is deliberately NO colour swatch. A canvas fill is painted through a
-- colour conversion: filling with #3fa7d6 and reading the pixel back gives
-- #52b4db, and no declared colour space changes that (hex, explicit
-- components, space="sRGB", space="P3" and asRGB all measured identical). A
-- swatch would therefore show a different colour from the one it reports, which
-- is worse than showing none — you are looking at the real (frozen) screen
-- anyway. The box marks the exact pixel that will be taken.
--
-- Upstream magnifies instead, and magnifying the screenshot would be both
-- faithful and colour-correct, but an image element scaled to a whole screen
-- renders empty inside a full-screen canvas. Left out rather than shipped
-- broken.
local MARK = 9
local LABEL_GAP = 14
local LABEL_W = 78
local LABEL_H = 18

-- Live picker state. Module-level rather than closed over: an hs.eventtap or
-- hs.canvas that nothing references is garbage collected and silently stops
-- working, which is the failure mode that leaves a frozen screen on screen with
-- no way to dismiss it.
local S = nil

-- ----------------------------------------------------------------- geometry --

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

-- Normalises a drag into a positive-extent rectangle, so dragging up-and-left
-- selects what it looks like it selects rather than a zero-size rect.
local function dragRect(a, b)
  local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
  local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
  return { x = math.floor(x1), y = math.floor(y1), w = math.floor(x2 - x1), h = math.floor(y2 - y1) }
end

-- A global screen point to a pixel in that screen's frozen screenshot. These
-- are NOT the same grid on a Retina display: the screenshot comes back at twice
-- the frame's width in points, so reading colorAt() with raw point coordinates
-- would sample a pixel up to half a screen away from the cursor.
local function imagePoint(frame, size, x, y)
  return {
    x = (x - frame.x) * (size.w / frame.w),
    y = (y - frame.y) * (size.h / frame.h),
  }
end

-- hs colour components are 0..1 floats. Rounded, not truncated — truncation
-- turns 0.999 into fe rather than ff — and clamped, because a colour converted
-- between spaces can land marginally outside the range.
local function hexOf(c)
  local function byte(v)
    return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5)))
  end
  return string.format("#%02x%02x%02x", byte(c.red), byte(c.green), byte(c.blue))
end

-- -------------------------------------------------------------- candidates --

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

-- ---------------------------------------------------------------- teardown --

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

local function finish(value)
  local st = S
  if not st then return end
  teardownOverlay()
  local drop = function() teardownFreeze(); S = nil end
  if not (st.keepFreeze and value) then
    teardownFreeze()
    S = nil
    drop = function() end
  end
  -- The callback runs AFTER the overlay is gone, so a caller that captures
  -- immediately never catches the dimming.
  st.callback(value, drop)
end

-- ------------------------------------------------------------------ colour --

-- The colour of the frozen pixel under a global point, or nil if the point is
-- on no screen. Read from the FREEZE rather than the live screen: it is the
-- image the user is looking at and clicking on, so it cannot disagree with what
-- they picked.
local function colorAtPoint(x, y)
  if not S then return nil end
  for i, f in ipairs(S.frames) do
    if contains({ x = f.x, y = f.y, w = f.w, h = f.h }, x, y) then
      local img = S.images[i]
      if not img then return nil end
      local p = imagePoint(f, img:size(), x, y)
      local ok, c = pcall(function() return img:colorAt(p) end)
      if ok and c then return hexOf(c) end
      return nil
    end
  end
  return nil
end

-- ------------------------------------------------------------------- paint --

-- Region mode: dim everything, punch the selection back out of it.
local function paintRegion()
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
      c[4].frame = { x = local_.x, y = local_.y + local_.h + 4, w = math.max(local_.w, 90), h = SWATCH_LABEL_H }
      c[4].text = string.format("%d × %d", sel.w, sel.h)
      c[4].action = (sel.w > 40 and sel.h > 20) and "fill" or "skip"
    else
      c[2].action = "skip"
      c[3].action = "skip"
      c[4].action = "skip"
    end
  end
end

-- Colour mode: the pixel under the cursor marked, and its hex beside it.
--
-- Deliberately NO dim. Dimming would change every colour on screen, so the
-- readout and the screen behind it would disagree and you would be picking by
-- eye from something that is not what you get.
local function paintPoint()
  local hex = colorAtPoint(S.cursor.x, S.cursor.y)
  S.hex = hex
  for i, c in ipairs(S.overlays) do
    local f = S.frames[i]
    local on = hex and contains({ x = f.x, y = f.y, w = f.w, h = f.h }, S.cursor.x, S.cursor.y)
    if not on then
      c[1].action = "skip"; c[2].action = "skip"
    else
      local lx, ly = math.floor(S.cursor.x - f.x), math.floor(S.cursor.y - f.y)
      c[1].frame = { x = lx - MARK / 2, y = ly - MARK / 2, w = MARK, h = MARK }
      c[1].action = "stroke"
      -- Flip to the other side of the cursor near an edge, so the hex is never
      -- half off the screen where it cannot be read.
      local tx = lx + LABEL_GAP
      local ty = ly + LABEL_GAP
      if tx + LABEL_W > f.w then tx = lx - LABEL_GAP - LABEL_W end
      if ty + LABEL_H > f.h then ty = ly - LABEL_GAP - LABEL_H end
      c[2].frame = { x = tx, y = ty, w = LABEL_W, h = LABEL_H }
      c[2].text = hex
      c[2].action = "fill"
    end
  end
end

local function paint()
  if not S then return end
  if S.kind == "point" then paintPoint() else paintRegion() end
end

-- ------------------------------------------------------------------ events --

local function onMouse(e)
  if not S then return false end
  local t = e:getType()
  -- The event's OWN location, not hs.mouse.absolutePosition(). Polling the
  -- cursor answers "where is the pointer now", which for a fast drag is
  -- somewhere past where the event happened — and for a synthesised event may
  -- be nowhere near it at all.
  local p = e:location() or hs.mouse.absolutePosition()
  S.cursor = { x = p.x, y = p.y }

  if S.kind == "point" then
    -- Taken on mouse UP, so you can press, nudge for pixel precision while
    -- watching the swatch, and release on the one you meant.
    if t == hs.eventtap.event.types.leftMouseUp then
      local hex = colorAtPoint(p.x, p.y)
      finish(hex)
      return true
    end
    paint()
    return true
  end

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
    if r and r.w > 0 and r.h > 0 then finish(rectString(r)) else finish(nil) end
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

-- ------------------------------------------------------------------- setup --

local function show()
  S.rects = candidates(S.mode)
  S.overlays = {}

  for i, scr in ipairs(hs.screen.allScreens()) do
    local f = S.frames[i]

    -- The frozen screenshot. scaleToFit, not a 1:1 blit: on a Retina display
    -- screencapture hands back twice as many pixels as the frame has points.
    local freeze = hs.canvas.new(f)
    freeze:appendElements({
      type = "image",
      image = S.images[i],
      imageScaling = "scaleToFit",
      frame = { x = 0, y = 0, w = f.w, h = f.h },
    })
    freeze:level(hs.drawing.windowLevels.screenSaver)
    freeze:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    freeze:show()
    S.freezes[#S.freezes + 1] = freeze

    local overlay = hs.canvas.new(f)
    if S.kind == "point" then
      overlay:appendElements(
        { type = "rectangle", action = "skip",                    -- 1: the pixel taken
          strokeColor = S.stroke, strokeWidth = 1,
          frame = { x = 0, y = 0, w = 0, h = 0 } },
        { type = "text", action = "skip", text = "",              -- 2: the hex
          textColor = S.stroke, textSize = 13, textAlignment = "left",
          frame = { x = 0, y = 0, w = 0, h = 0 } }
      )
    else
      overlay:appendElements(
        { -- 1: the dim, over the whole screen
          type = "rectangle", action = "fill",
          fillColor = { red = 0, green = 0, blue = 0, alpha = 0.45 },
          frame = { x = 0, y = 0, w = f.w, h = f.h } },
        { -- 2: punches the selection out of the dim, so the frozen screen shows
          -- through it at full brightness. `clear` erases what is already on the
          -- canvas rather than painting over it — a transparent fill would draw
          -- nothing at all and leave the dim intact.
          type = "rectangle", action = "fill",
          fillColor = { white = 1, alpha = 1 }, compositeRule = "clear",
          frame = { x = 0, y = 0, w = 0, h = 0 } },
        { -- 3: the selection's border, drawn after the hole so it is not erased
          type = "rectangle", action = "skip",
          strokeColor = S.stroke, strokeWidth = 2,
          frame = { x = 0, y = 0, w = 0, h = 0 } },
        { -- 4: the size readout
          type = "text", action = "skip", text = "",
          textColor = S.stroke, textSize = 13, textAlignment = "left",
          frame = { x = 0, y = 0, w = 0, h = 0 } }
      )
    end
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

  if S.kind ~= "point" then S.hint = rectAt(S.rects, S.cursor.x, S.cursor.y) end
  paint()
end

-- Freeze every screen first, and only then show anything: a canvas raised
-- before the last screenshot is taken ends up inside it.
--
-- -R with each screen's own frame rather than -D <n>: the display indices
-- screencapture uses are not documented to match hs.screen's order, while the
-- rectangle space is measured to be identical. One fewer thing to be wrong.
local function freezeThenShow()
  local screens = hs.screen.allScreens()
  local pending = #screens
  if pending == 0 then S = nil; return false end

  local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  S.frames = {}
  for i, scr in ipairs(screens) do
    local f = scr:fullFrame()
    S.frames[i] = f
    -- Not os.tmpname()..".png": tmpname CREATES the file it names, so appending
    -- an extension leaves that empty original behind on every pick. These are
    -- cleaned up by teardownFreeze.
    local path = string.format("%s/omamac-freeze-%d-%d.png", dir, hs.processInfo.processID, i)
    S.shots[i] = path
    local rect = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
    -- Kept in S so the task is referenced until it exits.
    S["task" .. i] = hs.task.new(SCREENCAPTURE, function()
      pending = pending - 1
      if pending == 0 and S then
        for j, p in ipairs(S.shots) do S.images[j] = hs.image.imageFromPath(p) end
        show()
      end
    end, { "-x", "-o", "-R", rect, path })
    S["task" .. i]:start()
  end
  return true
end

local function begin(kind, mode, opts, callback)
  local p = hs.mouse.absolutePosition()
  S = {
    kind = kind,
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
    images = {},
    frames = {},
    taps = nil,
  }
  if not freezeThenShow() then callback(nil, function() end) end
end

-- pick(mode, opts, callback)
--
--   mode      "smart"      freeform, with window/monitor rects hinted; a bare
--                          click snaps to the rectangle it landed in
--             "region"     freeform only, nothing hinted
--             "windows"    snap to a window or monitor
--             "fullscreen" the screen under the cursor, no interaction
--   opts      { keepFreeze = true, stroke = <hs colour> }
--   callback  (geometry|nil, dropFreeze)
--
-- Calling it while a pick is in progress cancels that one, the way invoking
-- upstream's screenshot again does (`pkill slurp && exit 0`).
function M.pick(mode, opts, callback)
  if S then finish(nil); return end
  mode = mode or "smart"
  opts = opts or {}

  if mode == "fullscreen" then
    local f = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
    callback(rectString({ x = f.x, y = f.y, w = f.w, h = f.h }), function() end)
    return
  end

  begin("region", mode, opts, callback)
end

-- pickPoint(opts, callback) — the colour under a clicked pixel, as "#rrggbb".
--
-- Omarchy's own entry is `pkill hyprpicker || hyprpicker -a`: a toggle that
-- picks one colour and copies it. Same here, including that invoking it while
-- it is already up cancels rather than stacking a second one.
function M.pickPoint(opts, callback)
  if S then finish(nil); return end
  begin("point", "point", opts or {}, callback)
end

function M.cancel()
  if S then finish(nil) end
end

function M.active() return S ~= nil end

-- Test seam. These are the whole of the pickers' geometry and colour maths —
-- which rectangle a click resolves to, how a drag becomes a rectangle, how a
-- rectangle is spelled, how a screen point maps onto a screenshot's pixels, and
-- how a colour becomes hex — and they are pure, so they can be checked under a
-- plain Lua interpreter with no Hammerspoon and no screen. Everything else here
-- needs a running WKWebView and a mouse, and is verified live instead.
M._rectAt = rectAt
M._dragRect = dragRect
M._rectString = rectString
M._imagePoint = imagePoint
M._hexOf = hexOf
M._CLICK_AREA = CLICK_AREA

return M

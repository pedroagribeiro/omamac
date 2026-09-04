-- omamac menu — Hammerspoon host. Thin shim: binds the hotkey, runs
-- `omamac menu-data`, injects the JSON as window.OMAMAC into menu/menu.html,
-- shows it in a transparent webview, and forwards the page's messages back to
-- the CLI. All logic lives in omamac itself.
require("hs.ipc")

local HOME = os.getenv("HOME")
-- Resolution order: a global set by the generated init.lua (Nix/home-manager
-- writes the store path in literally, since Hammerspoon.app inherits no shell
-- environment), then the OMAMAC_DIR env var (set for non-GUI invocations,
-- e.g. `hs` CLI or tests), then the checkout path as a last resort.
local OMAMAC = OMAMAC_DIR or os.getenv("OMAMAC_DIR") or (HOME .. "/personal/omamac")
-- OMAMAC_BIN (written by the generated init.lua alongside OMAMAC_DIR) points
-- at the WRAPPED binary — flake.nix's makeWrapper prefixes it with jq/curl/
-- fontconfig/bash on PATH. Falling back to OMAMAC .. "/bin/omamac" would run
-- the unwrapped copy under $out/share/omamac, which has only the hardcoded
-- PATH below to find those tools — silently breaking `font --list` and
-- `menu-data` on a Mac without them on one of those literal paths.
local OMAMAC_BIN_PATH = OMAMAC_BIN or os.getenv("OMAMAC_BIN") or (OMAMAC .. "/bin/omamac")
local PATH = "/opt/homebrew/bin:/run/current-system/sw/bin:" ..
             HOME .. "/.nix-profile/bin:/usr/bin:/bin:/usr/sbin:/sbin"

-- The region picker, upstream's omarchy-capture-region. Loaded by path rather
-- than `require`: OMAMAC is resolved at runtime and is not on package.path.
--
-- pcall so a broken picker costs Capture and not the whole menu — but the error
-- is PRINTED, not swallowed. A bare pcall with the error thrown away is how the
-- hs.json.encode(string) bug went unnoticed here for a whole feature's life.
local okRegion, Region = pcall(dofile, OMAMAC .. "/hammerspoon/region.lua")
if not okRegion then
  print("omamac: region picker failed to load: " .. tostring(Region))
  Region = nil
end

-- How long to wait after deleting the menu webview before freezing the screen.
-- Deleting the window is not the same as it having left the screen, and a panel
-- still composited when the freeze is taken ends up inside every screenshot.
--
-- Measured rather than guessed: sampling a patch of the panel's own frame, the
-- scrim reads 0.322 mean brightness while it is up and 0.339 once it is gone,
-- and every sample from 20ms after hide() onwards already reads the settled
-- value. This is that with room to spare, while still feeling instant.
local PANEL_CLEAR_DELAY = 0.15

-- Kept in a module-level local for the same reason the screen watcher below is:
-- an hs.timer that nothing references is garbage collected and never fires.
-- Observed exactly that — the panel closed, the picker never appeared, and
-- nothing was logged anywhere, because the timer had been collected between
-- being created and coming due.
local captureTimer = nil

local function shquote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(args)
  local cmd = string.format("PATH=%s %s %s", PATH, shquote(OMAMAC_BIN_PATH),
    table.concat(hs.fnutils.imap(args, shquote), " "))
  return hs.execute(cmd) or ""
end

-- hs.task.new with no streaming callback lets the child's stdout fill the
-- OS pipe buffer (~64KB) and block forever — Hammerspoon only drains stdout
-- on exit, so a child that's still blocked writing never exits, and `done`
-- never fires. This bit us for real: raising thumbnail resolution (sips -Z
-- 600 -> 1024, for the coverflow's 768px expanded view) pushed most preview
-- data URIs over that threshold. Verified live against all 8 tokyo-night
-- previews: only the 2 under 64KB ever returned; the other 6 (72KB-232KB)
-- never fired `done` even though `sips` had long since finished and the
-- thumbnail existed on disk — the callback was lost, not the work.
--
-- The fix is to pass hs.task.new a THIRD (streaming) callback, which fires
-- repeatedly as output arrives and must return true to keep streaming. That
-- drains the pipe continuously so the child never blocks on a full buffer.
-- Accumulate every streamed chunk and concatenate it with whatever `done`
-- ALSO receives (a task's final flush can arrive either through the stream
-- callback or as part of the done callback's own stdout argument — this
-- combines both rather than assuming one path is authoritative). Re-verified
-- live post-fix: all 8/8 previews arrived.
local function runAsync(args, done)
  local cmd = string.format("PATH=%s %s %s", PATH, shquote(OMAMAC_BIN_PATH),
    table.concat(hs.fnutils.imap(args, shquote), " "))
  local acc = {}
  local task = hs.task.new("/bin/sh",
    function(rc, stdout, stderr)
      local full = table.concat(acc) .. (stdout or "")
      if done then done(rc, full, stderr) end
    end,
    function(_, stdout, _)
      if stdout and #stdout > 0 then table.insert(acc, stdout) end
      return true
    end,
    { "-c", cmd })
  task:start()
end

-- Reads a cached thumbnail off disk and returns it as a data: URI, entirely
-- in-process. This exists because the image bytes CANNOT come back through
-- hs.task: with a streaming callback set, the completion callback can fire
-- before the final chunk has been delivered, and the tail is silently lost.
-- Measured against 19 real 1536x864 previews, 8 arrived truncated — every one
-- of them at an exact multiple of 1024 bytes, ending mid-base64, while every
-- intact one ended on a JPEG terminator. Raising the thumbnail resolution to
-- Omarchy's did not cause that; it just made an existing race easy to hit.
--
-- So `omamac preview --path` returns only the path (~100 bytes, always one
-- chunk) and the bytes are read here. Returns "" on any failure, which is the
-- same "not available" signal an empty stdout already meant.
local function fileDataURI(path)
  if not path or path == "" then return "" end
  local f = io.open(path, "rb")
  if not f then return "" end
  local bytes = f:read("*a")
  f:close()
  if not bytes or #bytes == 0 then return "" end
  return "data:image/jpeg;base64," .. hs.base64.encode(bytes)
end

-- The active theme's colours and font, cached from the menu-data the menu is
-- built with. Used to style the confirmation alert so it matches the card
-- rather than appearing in Hammerspoon's default black box. Re-read on every
-- open, so it follows a theme switch without any extra work.
local themeStyle = nil

-- #rrggbb -> the {red,green,blue,alpha} table Hammerspoon wants, falling back
-- to the menu's own defaults for anything malformed or missing.
local function rgb(hex, fallback)
  if type(hex) ~= "string" or not hex:match("^#%x%x%x%x%x%x$") then hex = fallback end
  return {
    red   = tonumber(hex:sub(2, 3), 16) / 255,
    green = tonumber(hex:sub(4, 5), 16) / 255,
    blue  = tonumber(hex:sub(6, 7), 16) / 255,
    alpha = 1,
  }
end

-- Matches the menu card: opaque theme background, a 1px foreground border,
-- square corners (Style.qml's cornerRadius is 0), and the theme's own
-- monospace font at the header's size. Only the keys hs.alert actually has —
-- it has no padding option, whatever the card uses.
local function alertStyle()
  local c = (themeStyle and themeStyle.colors) or {}
  local style = {
    fillColor   = rgb(c.background, "#1a1b26"),
    strokeColor = rgb(c.foreground, "#a9b1d6"),
    textColor   = rgb(c.foreground, "#a9b1d6"),
    strokeWidth = 1,
    radius      = 0,
    textSize    = 16,
  }
  -- Only set when known: hs.alert wants a real family name, and an empty
  -- string renders nothing at all.
  if themeStyle and type(themeStyle.font) == "string" and themeStyle.font ~= "" then
    style.textFont = themeStyle.font
  end
  return style
end

local menuWV = nil
local function hideMenu()
  if menuWV then menuWV:delete(); menuWV = nil end
end

-- Builds the JS the host pushes into the page to deliver a generated
-- thumbnail. `hs.json.encode` only accepts a TABLE (a bare string raises
-- "incorrect type 'string' for argument 1 (expected table)") — so this
-- encodes ONE table holding `name`, `uri` and `kind` and destructures it on
-- the JS side, rather than encoding each string separately at the call
-- site. That also gets the data: URI safely escaped for embedding in JS.
--
-- `kind` ("theme" or "bg") rides along because the page now has TWO picker
-- levels drawing previews, and it caches them in per-kind maps. Echoing the
-- kind back is what lets an arriving thumbnail land in the right one: the
-- name alone is ambiguous (a theme is "tokyo-night", a wallpaper is
-- "tokyo-night-0-swirl.jpg" — close enough that a future rename could
-- collide, and a silently mis-filed preview is invisible until the wrong
-- image shows up).
-- Pure aside from the encode call itself, so it can be exercised under a
-- plain Lua interpreter with a stub hs.json.encode — no webview needed.
local function previewScript(name, uri, kind)
  local payload = hs.json.encode({ name = name, uri = uri, kind = kind or "bg" })
  return "(function(p){window.omamacSetPreview(p.name,p.uri,p.kind)})(" .. payload .. ")"
end

local function onMessage(message)
  local b = message and message.body
  if type(b) ~= "table" then return end
  -- `cmd` alone is enough. It used to also require an argument, which silently
  -- swallowed every message for a verb that takes none — Deactivate posts
  -- `{cmd = "pause"}` and nothing happened, with no error anywhere.
  if b.action == "apply" and b.cmd then
    hideMenu()
    -- async: never block the UI on a switch.
    -- `args` carries a whole argv when one value is not enough — assigning a
    -- workspace needs a flag and a value. `arg` stays for the single-value
    -- case, and both are absent for a bare verb.
    local argv = { b.cmd }
    if type(b.args) == "table" then
      for _, a in ipairs(b.args) do argv[#argv + 1] = a end
    elseif b.arg ~= nil then
      argv[#argv + 1] = b.arg
    end
    runAsync(argv, function(_, stdout)
      -- An applied command that writes to STDOUT is reporting something the
      -- user has to see from a menu that has already closed. Every log_* in
      -- omamac goes to stderr and the setter paths print nothing, so this
      -- channel is free — `slack --copy` uses it, since a clipboard copy has
      -- no other way to confirm it happened.
      local msg = (stdout or ""):gsub("%s+$", "")
      if msg ~= "" then hs.alert.show(msg, alertStyle()) end
    end)
  elseif b.action == "previews" then
    local wv = menuWV
    -- ONE task for the whole level, never one per item. Measured against the
    -- real thing: 22 concurrent hs.tasks, each a trivial bash run that exited
    -- 0 with no stderr, delivered ZERO bytes of stdout to their Lua callbacks
    -- for 15 to 19 of them, varying run to run, while Hammerspoon logged
    -- "hs.task received output data from an unknown task". So omamac fans out
    -- internally (plain background jobs, which work) and answers with one
    -- "<name>\t<path>" line per item.
    --
    -- "bg" is the default so a message without a kind keeps the meaning it had
    -- before the Theme level existed: the current theme's wallpapers.
    local kind = (b.kind == "theme") and "theme" or "bg"
    local args = (kind == "theme") and { "preview", "--paths", "--theme" }
                                    or { "preview", "--paths" }
    runAsync(args, function(_, stdout)
      -- Compare IDENTITY, not truthiness. `wv` was captured while the menu was
      -- open, so it is always non-nil here and a bare `and wv` guards nothing.
      -- What can actually happen is the panel being closed (menuWV = nil) or
      -- replaced by a newly-opened one while these were generating.
      if wv ~= menuWV then return end
      local pushed = 0
      for line in (stdout or ""):gmatch("[^\n]+") do
        local name, path = line:match("^(.-)\t(.+)$")
        if name and path then
          local uri = fileDataURI(path)
          if uri == "" then
            -- omamac named a thumbnail this could not read. Silence here is
            -- exactly how a wallpaper stuck as a transparent placeholder went
            -- unnoticed once already, so say so.
            print(string.format("omamac: preview unreadable for %s", tostring(name)))
          else
            -- Was a bare `pcall` with the error thrown away, which is how the
            -- hs.json.encode(string) bug went unnoticed: it threw on every
            -- call and nothing ever surfaced it.
            local ok, err = pcall(function()
              wv:evaluateJavaScript(previewScript(name, uri, kind))
            end)
            if ok then
              pushed = pushed + 1
            else
              print(string.format("omamac: preview push failed for %s: %s", tostring(name), tostring(err)))
            end
          end
        end
      end
      if pushed == 0 then
        print(string.format("omamac: no %s previews available", kind))
      end
    end)
  elseif b.action == "capture" then
    hideMenu()
    if not Region then
      hs.alert.show("omamac: region picker unavailable", alertStyle())
      return
    end
    -- Wait for the panel to actually leave the screen before the picker freezes
    -- it — see PANEL_CLEAR_DELAY.
    if captureTimer then captureTimer:stop() end
    captureTimer = hs.timer.doAfter(PANEL_CLEAR_DELAY, function()
      local shot = (b.kind == "screenshot")
      -- The picker is drawn in the theme's accent, so it looks like the menu it
      -- came from. rgb()'s fallback is a HEX STRING, not a colour table: it
      -- substitutes the fallback for the value and then indexes it as a string,
      -- so a table there crashes on exactly the themes that have no accent to
      -- read. Computed before the branch below, which also needs it.
      local stroke = rgb(themeStyle and themeStyle.colors and themeStyle.colors.accent, "#ffffff")
      -- Colour picking has no rectangle and nothing to capture afterwards: the
      -- picker reads the pixel off the freeze and hands back the hex.
      if b.kind == "color" then
        Region.pickPoint({ stroke = stroke }, function(hex)
          if not hex then return end
          runAsync({ "capture", "--color", hex }, function(_, stdout)
            local msg = (stdout or ""):gsub("%s+$", "")
            if msg ~= "" then hs.alert.show(msg, alertStyle()) end
          end)
        end)
        return
      end
      Region.pick("smart",
        -- A screenshot is taken FROM the frozen screen, so the freeze outlives
        -- the pick; a recording must see live content, so it does not.
        { keepFreeze = shot, stroke = stroke },
        function(geo, dropFreeze)
          if not geo then dropFreeze(); return end
          local argv = shot and { "capture", "--screenshot", "--region", geo }
                            or { "capture", "--record", "--region", geo }
          if not shot and b.audio then argv[#argv + 1] = "--audio" end
          runAsync(argv, function(_, stdout)
            dropFreeze()
            local msg = (stdout or ""):gsub("%s+$", "")
            if msg ~= "" then hs.alert.show(msg, alertStyle()) end
          end)
        end)
    end)
  elseif b.action == "close" then
    hideMenu()
  end
end

local function openMenu()
  hideMenu()
  local f = io.open(OMAMAC .. "/menu/menu.html", "r")
  if not f then hs.alert.show("omamac: menu.html not found"); return end
  -- Escape `<` so a name containing the literal text "</script>" cannot close
  -- the tag early and corrupt the page. < is valid JSON and parses back to
  -- "<" in JS, so the data is unchanged.
  local json = run({ "menu-data" }):gsub("<", "\\u003c")
  -- Same payload the page is built from, kept for the alert's styling. pcall
  -- because a decode failure must not stop the menu opening — the alert simply
  -- falls back to the built-in colours.
  local ok, data = pcall(hs.json.decode, json)
  if ok and type(data) == "table" then
    themeStyle = { colors = data.colors, font = data.font and data.font.current }
  end
  local html = "<script>window.OMAMAC = " .. json .. ";</script>\n" .. f:read("*a")
  f:close()

  -- Full-screen, not a centred box: the page paints a full-viewport scrim
  -- and centres its own card/coverflow, so a smaller webview frame would
  -- just clip both the dim and the coverflow (which needs far more width
  -- than a fixed 900px ever gave it). fullFrame(), not frame(): frame()
  -- excludes the menu bar / Dock inset, which would leave a sliver of
  -- undimmed desktop at the top of the screen.
  local scr = hs.screen.mainScreen():fullFrame()
  local ucc = hs.webview.usercontent.new("omamac")
  ucc:setCallback(onMessage)
  menuWV = hs.webview.new(
    { x = scr.x, y = scr.y, w = scr.w, h = scr.h },
    { developerExtrasEnabled = false }, ucc)
  menuWV:windowStyle({ "borderless" })
  menuWV:allowTextEntry(true)
  menuWV:transparent(true)
  menuWV:level(hs.drawing.windowLevels.modalPanel)
  menuWV:deleteOnClose(true)
  menuWV:html(html)
  menuWV:show():bringToFront(true)
  local win = menuWV:hswindow()
  if win then win:focus() end
end

-- cmd+alt+O, not cmd+alt+SPACE. macOS holds cmd+alt+space for "Show Finder
-- search window"; disabling that preference does not release the running
-- registration without a re-login, so RegisterEventHotKey fails with -9878.
-- Held rather than discarded: pausing has to be able to give these back to the
-- system, and a bound hotkey is the only thing standing between omamac and
-- another app that wants the same chord.
local hotkeys = {
  hs.hotkey.bind({ "cmd", "alt" }, "o", openMenu),
  hs.hotkey.bind({ "cmd", "ctrl" }, "space", function() runAsync({ "bg", "--next" }) end),
}

-- Re-assert the wallpaper when displays change.
--
-- macOS keeps a wallpaper per Space, and the display configuration decides
-- which Spaces exist: connecting a monitor creates them, disconnecting
-- destroys and merges them. Across that transition macOS restores its OWN
-- remembered picture for each Space, overriding whatever omamac set — which
-- made the wallpaper silently revert to a previous theme's while every other
-- target stayed on the current one. Observed live: state said tokyo-night
-- while both desktops were showing osaka-jade's wallpaper.
--
-- This is the only place a display change is observable; the CLI has no way
-- to know one happened. `bg --reapply` is a no-op when nothing has drifted,
-- so this is safe to fire liberally.
--
-- Kept in a module-level local: an hs.screen.watcher that nothing references
-- is garbage collected and silently stops firing.
local screenWatcher = nil
local reassertTimer = nil
local function scheduleWallpaperReassert()
  -- One connect or disconnect emits several callbacks, and the Spaces are not
  -- settled when the first arrives. Coalesce them, and give macOS a moment to
  -- finish rearranging before asking it to change anything.
  if reassertTimer then reassertTimer:stop() end
  reassertTimer = hs.timer.doAfter(3, function()
    runAsync({ "bg", "--reapply" })
  end)
end
screenWatcher = hs.screen.watcher.new(scheduleWallpaperReassert)

-- Pausing.
--
-- The two hotkeys above and the screen watcher below are everything omamac does
-- without being asked, so pausing is exactly: release them. Nothing that any
-- tool reads is touched — see bin/omamac-pause for why undoing the theming is
-- not what this does.
--
-- The truth lives in a marker file, not in this process, for two reasons: a
-- paused omamac must come back paused after a Hammerspoon reload, and `omamac
-- resume` is typed in a terminal, which cannot reach into this Lua state. A
-- path watcher on the state directory is what closes that gap.
local STATE_DIR = os.getenv("OMAMAC_STATE") or (HOME .. "/.local/state/omamac")
local pauseWatcher = nil

local function isPaused()
  local f = io.open(STATE_DIR .. "/paused", "r")
  if not f then return false end
  local v = f:read("*a") or ""
  f:close()
  return v:gsub("%s", "") ~= ""
end

local function applyActivation()
  local paused = isPaused()
  for _, k in ipairs(hotkeys) do
    if paused then k:disable() else k:enable() end
  end
  if paused then screenWatcher:stop() else screenWatcher:start() end
  return paused
end

-- The directory has to exist before it can be watched, and on a fresh install
-- nothing has written state yet. Without this the watcher attaches to a path
-- that is not there and `omamac resume` appears to do nothing until Hammerspoon
-- is reloaded.
--
-- os.execute, not hs.fs: this runs at LOAD, and reaching for another hs module
-- here makes the host unloadable anywhere that module is absent — which broke
-- every one of this file's own test harnesses the moment it was tried. Plain
-- Lua costs one mkdir at startup and depends on nothing.
os.execute("mkdir -p " .. shquote(STATE_DIR))
pauseWatcher = hs.pathwatcher.new(STATE_DIR, function() applyActivation() end)
pauseWatcher:start()

-- At load, not just on change: this is what makes a pause survive a reload.
applyActivation()

OmamacMenu = {
  open = openMenu, hide = hideMenu, reassert = scheduleWallpaperReassert,
  paused = isPaused, refresh = applyActivation,
}

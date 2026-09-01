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

local menuWV = nil
local function hideMenu()
  if menuWV then menuWV:delete(); menuWV = nil end
end

-- Builds the JS the host pushes into the page to deliver a generated
-- thumbnail. `hs.json.encode` only accepts a TABLE (a bare string raises
-- "incorrect type 'string' for argument 1 (expected table)") — so this
-- encodes ONE table holding both `name` and `uri` and destructures it on
-- the JS side, rather than encoding each string separately at the call
-- site. That also gets the data: URI safely escaped for embedding in JS.
-- Pure aside from the encode call itself, so it can be exercised under a
-- plain Lua interpreter with a stub hs.json.encode — no webview needed.
local function previewScript(name, uri)
  local payload = hs.json.encode({ name = name, uri = uri })
  return "(function(p){window.omamacSetPreview(p.name,p.uri)})(" .. payload .. ")"
end

local function onMessage(message)
  local b = message and message.body
  if type(b) ~= "table" then return end
  if b.action == "apply" and b.cmd and b.arg then
    hideMenu()
    runAsync({ b.cmd, b.arg })          -- async: never block the UI on a switch
  elseif b.action == "preview" and b.name then
    local wv = menuWV
    runAsync({ "preview", b.name }, function(_, stdout)
      stdout = (stdout or ""):gsub("%s+$", "")
      -- Compare IDENTITY, not truthiness. `wv` was captured while the menu was
      -- open, so it is always non-nil here and a bare `and wv` guards nothing.
      -- What can actually happen is the panel being closed (menuWV = nil) or
      -- replaced by a newly-opened one while this thumbnail was generating.
      if wv == menuWV then
        -- An empty stdout means omamac-preview bailed silently (missing
        -- source, sips failure, a wallpaper still mid-download — see
        -- bin/omamac-bg's atomic-fetch fix). That USED to be dropped here
        -- with no trace at all — exactly how a wallpaper stuck as a
        -- transparent placeholder went unnoticed. Log it, and push the
        -- empty result through to the page anyway: omamacSetPreview(name,
        -- "") tells the page "not available yet", so it can drop the name
        -- from its own in-flight set and retry (bounded — see menu.html).
        if stdout == "" then
          print(string.format("omamac: preview empty for %s", tostring(b.name)))
        end
        -- Was a bare `pcall` with the error thrown away, which is exactly
        -- how the hs.json.encode(string) bug above went unnoticed: it threw
        -- on every single call and nothing ever surfaced that. Log on
        -- failure, with the name, so a future break here is loud instead of
        -- silent.
        local ok, err = pcall(function()
          wv:evaluateJavaScript(previewScript(b.name, stdout))
        end)
        if not ok then
          print(string.format("omamac: preview push failed for %s: %s", tostring(b.name), tostring(err)))
        end
      end
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
hs.hotkey.bind({ "cmd", "alt" }, "o", openMenu)
hs.hotkey.bind({ "cmd", "ctrl" }, "space", function() runAsync({ "bg", "--next" }) end)

OmamacMenu = { open = openMenu, hide = hideMenu }

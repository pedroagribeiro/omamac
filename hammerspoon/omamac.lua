-- omamac menu — Hammerspoon host. Thin shim: binds the hotkey, runs
-- `omamac menu-data`, injects the JSON as window.OMAMAC into menu/menu.html,
-- shows it in a transparent webview, and forwards the page's messages back to
-- the CLI. All logic lives in omamac itself.
require("hs.ipc")

local HOME = os.getenv("HOME")
local OMAMAC = os.getenv("OMAMAC_DIR") or (HOME .. "/personal/omamac")
local PATH = "/opt/homebrew/bin:/run/current-system/sw/bin:" ..
             HOME .. "/.nix-profile/bin:/usr/bin:/bin:/usr/sbin:/sbin"

local function shquote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(args)
  local cmd = string.format("PATH=%s %s/bin/omamac %s", PATH, shquote(OMAMAC),
    table.concat(hs.fnutils.imap(args, shquote), " "))
  return hs.execute(cmd) or ""
end

local function runAsync(args, done)
  local cmd = string.format("PATH=%s %s/bin/omamac %s", PATH, shquote(OMAMAC),
    table.concat(hs.fnutils.imap(args, shquote), " "))
  hs.task.new("/bin/sh", done, { "-c", cmd }):start()
end

local menuWV = nil
local function hideMenu()
  if menuWV then menuWV:delete(); menuWV = nil end
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
      if stdout ~= "" and wv then
        pcall(function()
          wv:evaluateJavaScript("window.omamacSetPreview(" ..
            hs.json.encode(b.name) .. "," .. hs.json.encode(stdout) .. ")")
        end)
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
  local html = "<script>window.OMAMAC = " .. run({ "menu-data" }) .. ";</script>\n" ..
               f:read("*a")
  f:close()

  local scr = hs.screen.mainScreen():frame()
  local w, h = 900, 760
  local ucc = hs.webview.usercontent.new("omamac")
  ucc:setCallback(onMessage)
  menuWV = hs.webview.new(
    { x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 2, w = w, h = h },
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

hs.hotkey.bind({ "cmd", "alt" }, "space", openMenu)
hs.hotkey.bind({ "cmd", "ctrl" }, "space", function() runAsync({ "bg", "--next" }) end)

OmamacMenu = { open = openMenu, hide = hideMenu }

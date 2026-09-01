#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
HOST="$OMAMAC_ROOT/hammerspoon/omamac.lua"

test_host_parses() {
  [ -f "$HOST" ] || { fail "hammerspoon/omamac.lua missing"; return; }
  local rc; lua_parse_check "$HOST"; rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no Lua parser available — cannot verify the host"
  else
    assert_eq 0 "$rc" "hammerspoon/omamac.lua must parse"
  fi
}

test_binds_both_hotkeys() {
  local src; src=$(cat "$HOST")
  # cmd+alt+space opens the menu; cmd+ctrl+space cycles the wallpaper.
  assert_contains "$src" '{ "cmd", "alt" }, "o"'
  assert_contains "$src" '{ "cmd", "ctrl" }, "space"'
}

test_speaks_the_page_contract() {
  local src; src=$(cat "$HOST")
  # These four names are the page↔host contract from Task 14. If the page is
  # rewritten and one is dropped, the menu renders but does nothing.
  assert_contains "$src" "menu-data"
  assert_contains "$src" "omamacSetPreview"
  assert_contains "$src" 'b.action == "apply"'
  assert_contains "$src" 'b.action == "previews"'
  assert_contains "$src" 'b.action == "close"'
  # The page is injected as window.OMAMAC ahead of the file's own script.
  assert_contains "$src" "window.OMAMAC"
}

test_resolves_omamac_bin_with_wrapped_fallback_chain() {
  local src; src=$(cat "$HOST")
  # OMAMAC_BIN (set by the generated init.lua alongside OMAMAC_DIR) must be
  # preferred — it points at the WRAPPED binary flake.nix's makeWrapper
  # prefixes with jq/curl/fontconfig/bash on PATH. The unwrapped
  # OMAMAC .. "/bin/omamac" fallback stays for non-Nix / test invocations.
  assert_contains "$src" "OMAMAC_BIN_PATH = OMAMAC_BIN"
  assert_contains "$src" 'os.getenv("OMAMAC_BIN")'
  assert_contains "$src" 'OMAMAC .. "/bin/omamac"'
}

test_run_and_runasync_invoke_the_resolved_binary() {
  local src; src=$(cat "$HOST")
  # run() and runAsync() must both shell out to OMAMAC_BIN_PATH, not build
  # "OMAMAC .. /bin/omamac" directly at the call site — that would bypass the
  # OMAMAC_BIN preference above entirely.
  local n; n=$(printf '%s' "$src" | grep -c 'shquote(OMAMAC_BIN_PATH)')
  assert_eq 2 "$n" "run() and runAsync() must both invoke the resolved OMAMAC_BIN_PATH"
}

# Extracts the `previewScript(name, uri)` function verbatim so it can be
# executed in isolation, outside Hammerspoon. It has exactly one top-level
# `end` (no nested blocks), so a simple start/stop awk scan is exact.
extract_preview_script() {
  awk '/^local function previewScript/{f=1} f{print} f && /^end$/{exit}' "$HOST"
}

# Runs the extracted previewScript against a stub hs.json.encode that mimics
# the REAL function's contract as verified against the running Hammerspoon:
# it raises "incorrect type '<type>' for argument 1 (expected table)" when
# given anything but a table, and otherwise returns a JSON object string.
# This is what actually catches the bug this file is named after: the old
# call site handed hs.json.encode two bare strings, which this stub would
# raise on exactly like the real one silently did (behind a bare pcall)
# every single time a thumbnail arrived.
test_preview_script_pushes_a_single_table_and_produces_valid_js() {
  local extracted; extracted=$(extract_preview_script)
  if [ -z "$extracted" ]; then
    fail "previewScript(name, uri) not found in $HOST — has the host→page push been reverted or renamed?"
    return
  fi

  local harness="$TMPDIR_TEST/preview_script_harness.lua"
  {
    cat <<'LUA'
-- Stub for hs.json.encode. Contract verified against a running Hammerspoon:
-- a bare string raises; a table succeeds and is serialised.
local function stub_encode(t)
  if type(t) ~= "table" then
    error(string.format("incorrect type '%s' for argument 1 (expected table)", type(t)))
  end
  local esc = function(s)
    s = tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    return '"' .. s .. '"'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = esc(k) .. ":" .. esc(t[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
hs = { json = { encode = stub_encode } }

LUA
    printf '%s\n' "$extracted"
    cat <<'LUA'

local ok, result = pcall(previewScript, "a.jpg", "data:image/jpeg;base64,AAAA")
if not ok then
  error("previewScript raised (this is the bug: a bare string reached hs.json.encode): " .. tostring(result))
end
if type(result) ~= "string" then
  error("previewScript must return a string, got a " .. type(result))
end
if not result:find("omamacSetPreview", 1, true) then
  error("result does not call omamacSetPreview: " .. result)
end
if not result:find("data:image/jpeg;base64,AAAA", 1, true) then
  error("result does not carry the URI through: " .. result)
end
print("PREVIEW_JS_START")
print(result)
print("PREVIEW_JS_END")
LUA
  } > "$harness"

  local out rc
  out=$(lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify the host->page push"
    return
  fi
  assert_eq 0 "$rc" "previewScript must run cleanly against a real-shaped hs.json.encode stub, got: $out"
  [ "$rc" -eq 0 ] || return

  if ! command -v node >/dev/null 2>&1; then
    fail "no JS engine available to verify the produced JS parses"
    return
  fi
  local js
  js=$(printf '%s\n' "$out" | sed -n '/^PREVIEW_JS_START$/,/^PREVIEW_JS_END$/p' | sed '1d;$d')
  [ -n "$js" ] || { fail "harness produced no JS payload; full output: $out"; return; }
  printf '%s\n' "$js" > "$TMPDIR_TEST/preview.js"
  node --check "$TMPDIR_TEST/preview.js" 2>"$TMPDIR_TEST/err" \
    || fail "produced JS does not parse: $(cat "$TMPDIR_TEST/err")"
}

# Drives the REAL onMessage handler (not just previewScript in isolation) by
# stubbing every hs.* surface it touches and dofile-ing the whole host, then
# capturing the onMessage callback via a stubbed
# hs.webview.usercontent.new(...):setCallback(...). hs.task.new's stub
# invokes its callback SYNCHRONOUSLY so the async preview round-trip runs to
# completion inside this single Lua process, with a fake webview recording
# every evaluateJavaScript(...) call it receives.
#
# This is what actually catches the bug this file is named after happening
# again: a source-text grep for `stdout ~= ""` would keep passing even if
# someone reintroduced a silent-skip under a different guard. Only running
# the real conditional, with an empty preview response, proves both halves
# of the fix — the omamac: preview empty log line AND the
# omamacSetPreview(name, "") push actually reaching the page.
test_unreadable_thumbnail_is_logged_and_not_pushed() {
  local harness="$TMPDIR_TEST/empty_preview_harness.lua"
  # Single-quoted heredoc: every backslash below must survive into the Lua
  # file byte-for-byte (this is a JSON-escaping routine), so bash must not
  # touch it. The host path is substituted separately via HAMMERSPOON_HOST,
  # read with os.getenv below, rather than interpolated into the heredoc.
  cat > "$harness" <<'LUAEOF'
-- hs.ipc is a real Hammerspoon module; intercept require() before the host
-- file's own require("hs.ipc") call reaches the module system.
package.loaded["hs.ipc"] = {}

local evaljs_calls = {}
local task_stdout = ""

local function stub_encode(t)
  if type(t) ~= "table" then
    error(string.format("incorrect type '%s' for argument 1 (expected table)", type(t)))
  end
  local esc = function(s)
    s = tostring(s):gsub('\\\\', '\\\\\\\\'):gsub('"', '\\\\"')
    return '"' .. s .. '"'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = esc(k) .. ":" .. esc(t[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local fakeWebview = {}
fakeWebview.__index = fakeWebview
function fakeWebview:windowStyle() return self end
function fakeWebview:allowTextEntry() return self end
function fakeWebview:transparent() return self end
function fakeWebview:level() return self end
function fakeWebview:deleteOnClose() return self end
function fakeWebview:html() return self end
function fakeWebview:show() return self end
function fakeWebview:bringToFront() return self end
function fakeWebview:hswindow() return nil end
function fakeWebview:delete() end
function fakeWebview:evaluateJavaScript(js) table.insert(evaljs_calls, js) end

local capturedCallback = nil

hs = {
  ipc = {},
  fnutils = { imap = function(t, fn) local r = {} for i, v in ipairs(t) do r[i] = fn(v) end return r end },
  json = { encode = stub_encode },
  execute = function(cmd) return "" end,
  hotkey = { bind = function() end },
  screen = { mainScreen = function() return { fullFrame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
  webview = {
    usercontent = { new = function(name) return { setCallback = function(self, cb) capturedCallback = cb end } end },
    new = function(frame, opts, ucc) return setmetatable({}, fakeWebview) end,
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  alert = { show = function() end },
  -- Deterministic stand-in for hs.base64.encode: the host must read the
  -- WHOLE file and hand its bytes to this, so echoing the byte count is
  -- enough to prove both without shipping a Lua base64 implementation.
  base64 = { encode = function(b) return "B64<" .. #b .. ">" end },
  task = {
    new = function(path, doneCb, args)
      return { start = function() doneCb(0, task_stdout, "") end }
    end,
  },
}

local hostPath = os.getenv("HAMMERSPOON_HOST")
local ok, err = pcall(dofile, hostPath)
if not ok then
  error("failed to load " .. tostring(hostPath) .. " under stubs: " .. tostring(err))
end

OmamacMenu.open()
if not capturedCallback then
  error("openMenu() never registered a message callback via ucc:setCallback")
end

-- omamac named a thumbnail the host then cannot read (deleted between the
-- two steps, or a partial write). This must be reported, not swallowed:
-- silence here is exactly how a wallpaper stuck as a transparent placeholder
-- went unnoticed once already.
task_stdout = "1-alpha.jpg\t/definitely/not/a/real/thumbnail.jpg"
capturedCallback({ body = { action = "previews", kind = "bg" } })

print("EMPTY_PUSH_RESULT_START")
print("evaljs_count=" .. tostring(#evaljs_calls))
print("evaljs_payload=" .. tostring(evaljs_calls[1] or "NONE"))
print("EMPTY_PUSH_RESULT_END")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify the empty-preview push"
    return
  fi
  assert_eq 0 "$rc" "empty-preview harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  assert_contains "$out" "omamac: preview unreadable for 1-alpha.jpg" \
    "an unreadable thumbnail must be logged with the item's name, not dropped silently"
  assert_contains "$out" "omamac: no bg previews available" \
    "a level where nothing could be read must say so"

  local count; count=$(printf '%s\n' "$out" | sed -n 's/^evaljs_count=//p')
  assert_eq "0" "$count" \
    "an unreadable thumbnail must NOT be pushed: an empty src renders as a broken image, and the page's placeholder is the correct thing to leave in place"
}

# Structural regression test for the pipe-deadlock fix: hs.task.new with no
# streaming callback lets a child's stdout fill the OS pipe buffer (~64KB)
# and block forever, since Hammerspoon only drains stdout on exit — so a
# large preview (raised to sips -Z 1024 for the coverflow) silently never
# fires `done`. Verified live: only previews under 64KB ever returned; the
# fix is a THIRD (streaming) argument to hs.task.new that drains the pipe as
# output arrives. This cannot be proven behaviourally from a shell-based
# test harness (nothing here can actually fill a real OS pipe buffer and
# show it deadlocks) — this only asserts the STRUCTURE that makes the
# regression impossible to reintroduce silently: hs.task.new must be called
# with 4 arguments, and the 3rd must be a function. Against the unfixed
# three-argument call (path, done, args) this fails, because select('#',...)
# is 3 and the 3rd argument is a table, not a function.
test_runasync_gives_hs_task_new_a_streaming_callback() {
  local harness="$TMPDIR_TEST/streaming_callback_harness.lua"
  cat > "$harness" <<'LUAEOF'
package.loaded["hs.ipc"] = {}

local captured_argc = nil
local captured_arg3_type = nil
local captured_arg4_type = nil

local function stub_encode(t) return "{}" end

local fakeWebview = {}
fakeWebview.__index = fakeWebview
function fakeWebview:windowStyle() return self end
function fakeWebview:allowTextEntry() return self end
function fakeWebview:transparent() return self end
function fakeWebview:level() return self end
function fakeWebview:deleteOnClose() return self end
function fakeWebview:html() return self end
function fakeWebview:show() return self end
function fakeWebview:bringToFront() return self end
function fakeWebview:hswindow() return nil end
function fakeWebview:delete() end
function fakeWebview:evaluateJavaScript(js) end

local capturedCallback = nil

hs = {
  ipc = {},
  fnutils = { imap = function(t, fn) local r = {} for i, v in ipairs(t) do r[i] = fn(v) end return r end },
  json = { encode = stub_encode },
  execute = function(cmd) return "" end,
  hotkey = { bind = function() end },
  screen = { mainScreen = function() return { fullFrame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
  webview = {
    usercontent = { new = function(name) return { setCallback = function(self, cb) capturedCallback = cb end } end },
    new = function(frame, opts, ucc) return setmetatable({}, fakeWebview) end,
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  alert = { show = function() end },
  -- Deterministic stand-in for hs.base64.encode: the host must read the
  -- WHOLE file and hand its bytes to this, so echoing the byte count is
  -- enough to prove both without shipping a Lua base64 implementation.
  base64 = { encode = function(b) return "B64<" .. #b .. ">" end },
  task = {
    new = function(...)
      captured_argc = select('#', ...)
      local a1, a2, a3, a4 = ...
      captured_arg3_type = type(a3)
      captured_arg4_type = type(a4)
      return { start = function() end }
    end,
  },
}

local hostPath = os.getenv("HAMMERSPOON_HOST")
local ok, err = pcall(dofile, hostPath)
if not ok then
  error("failed to load " .. tostring(hostPath) .. " under stubs: " .. tostring(err))
end

OmamacMenu.open()
if not capturedCallback then
  error("openMenu() never registered a message callback via ucc:setCallback")
end

-- Drive the exact path that deadlocked live: a preview request, which goes
-- through runAsync with a `done` callback (apply/cycle also use runAsync,
-- but with tiny output where the bug never bit).
capturedCallback({ body = { action = "previews", kind = "bg" } })

print("STREAM_CB_RESULT_START")
print("argc=" .. tostring(captured_argc))
print("arg3_type=" .. tostring(captured_arg3_type))
print("arg4_type=" .. tostring(captured_arg4_type))
print("STREAM_CB_RESULT_END")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify the streaming callback"
    return
  fi
  assert_eq 0 "$rc" "streaming-callback harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  local argc; argc=$(printf '%s\n' "$out" | sed -n 's/^argc=//p')
  local arg3_type; arg3_type=$(printf '%s\n' "$out" | sed -n 's/^arg3_type=//p')
  local arg4_type; arg4_type=$(printf '%s\n' "$out" | sed -n 's/^arg4_type=//p')

  assert_eq "4" "$argc" \
    "runAsync must call hs.task.new(path, done, stream, args) — a 3-argument call has no streaming callback, which is exactly the pipe-deadlock regression"
  assert_eq "function" "$arg3_type" \
    "the 3rd argument to hs.task.new must be the streaming callback (a function), not the args table"
  assert_eq "table" "$arg4_type" \
    "the 4th argument to hs.task.new must be the args table"
}

# Behavioural companion to the structural test above, and the regression test
# for the truncation that made 8 of 19 real previews arrive as flat colour.
#
# The host asks for a PATH now, never the bytes — `omamac preview --path`.
# This streams that path across several hs.task callback invocations with
# `done`'s own stdout empty (the shape a real chunked read takes) and proves
# two things at once: the chunks are concatenated in order into a usable path,
# and the host then reads that file's FULL contents itself. If the bytes still
# came from stdout, or the concatenation dropped a chunk, the pushed URI would
# not carry the file's real byte count.
test_runasync_reassembles_the_path_and_encodes_the_file_itself() {
  local harness="$TMPDIR_TEST/streaming_accumulate_harness.lua"
  local payload="$TMPDIR_TEST/thumb.jpg"
  # 5000 bytes of known content — the size is what the stub base64 reports.
  python3 -c "import sys; sys.stdout.write('x' * 5000)" > "$payload" 2>/dev/null \
    || printf '%05000d' 0 > "$payload"
  local size; size=$(wc -c < "$payload" | tr -d ' ')

  cat > "$harness" <<'LUAEOF'
package.loaded["hs.ipc"] = {}

local function stub_encode(t)
  if type(t) ~= "table" then
    error(string.format("incorrect type '%s' for argument 1 (expected table)", type(t)))
  end
  local esc = function(s)
    s = tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    return '"' .. s .. '"'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = esc(k) .. ":" .. esc(t[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local evaljs_calls = {}

local fakeWebview = {}
fakeWebview.__index = fakeWebview
function fakeWebview:windowStyle() return self end
function fakeWebview:allowTextEntry() return self end
function fakeWebview:transparent() return self end
function fakeWebview:level() return self end
function fakeWebview:deleteOnClose() return self end
function fakeWebview:html() return self end
function fakeWebview:show() return self end
function fakeWebview:bringToFront() return self end
function fakeWebview:hswindow() return nil end
function fakeWebview:delete() end
function fakeWebview:evaluateJavaScript(js) table.insert(evaljs_calls, js) end

local capturedCallback = nil
local payloadPath = os.getenv("PREVIEW_PAYLOAD")

hs = {
  ipc = {},
  fnutils = { imap = function(t, fn) local r = {} for i, v in ipairs(t) do r[i] = fn(v) end return r end },
  json = { encode = stub_encode },
  base64 = { encode = function(b) return "B64<" .. #b .. ">" end },
  execute = function(cmd) return "" end,
  hotkey = { bind = function() end },
  screen = { mainScreen = function() return { fullFrame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
  webview = {
    usercontent = { new = function(name) return { setCallback = function(self, cb) capturedCallback = cb end } end },
    new = function(frame, opts, ucc) return setmetatable({}, fakeWebview) end,
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  alert = { show = function() end },
  task = {
    -- A real read arrives in chunks while `done`'s own stdout is empty. Split
    -- the path across three of them, mid-component, so any dropped or
    -- reordered chunk yields a path that cannot be opened.
    new = function(path, doneCb, streamCb, args)
      return {
        start = function()
          local line = "big.jpg\t" .. payloadPath
          local n2 = #line
          local a2 = math.floor(n2 / 3)
          local b2 = math.floor(2 * n2 / 3)
          streamCb(nil, line:sub(1, a2), "")
          streamCb(nil, line:sub(a2 + 1, b2), "")
          streamCb(nil, line:sub(b2 + 1), "")
          doneCb(0, "", "")
        end,
      }
    end,
  },
}

local hostPath = os.getenv("HAMMERSPOON_HOST")
local ok, err = pcall(dofile, hostPath)
if not ok then
  error("failed to load " .. tostring(hostPath) .. " under stubs: " .. tostring(err))
end

OmamacMenu.open()
if not capturedCallback then
  error("openMenu() never registered a message callback via ucc:setCallback")
end

capturedCallback({ body = { action = "previews", kind = "bg" } })

io.write("ACCUMULATE_RESULT_START\n")
io.write("evaljs_count=" .. tostring(#evaljs_calls) .. "\n")
io.write("evaljs_payload=" .. tostring(evaljs_calls[1] or "NONE") .. "\n")
io.write("ACCUMULATE_RESULT_END\n")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" PREVIEW_PAYLOAD="$payload" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify path reassembly"
    return
  fi
  assert_eq 0 "$rc" "accumulate harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  assert_contains "$out" "evaljs_count=1" "a streamed preview must still be pushed to the page exactly once"
  assert_contains "$out" "data:image/jpeg;base64,B64<${size}>" \
    "the pushed URI must be the FULL file read by the host, proving the line survived chunking and the bytes never came through the pipe"
  assert_contains "$out" '"name":"big.jpg"' \
    "the name must come from the response line, bound to the file it named"
}

test_preview_kind_routes_to_the_right_omamac_subcommand() {
  local harness="$TMPDIR_TEST/preview_kind_harness.lua"
  cat > "$harness" <<'LUAEOF'
package.loaded["hs.ipc"] = {}

local commands = {}
local evaljs_calls = {}

local function stub_encode(t)
  if type(t) ~= "table" then
    error(string.format("incorrect type '%s' for argument 1 (expected table)", type(t)))
  end
  local esc = function(s)
    s = tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    return '"' .. s .. '"'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = esc(k) .. ":" .. esc(t[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local fakeWebview = {}
fakeWebview.__index = fakeWebview
function fakeWebview:windowStyle() return self end
function fakeWebview:allowTextEntry() return self end
function fakeWebview:transparent() return self end
function fakeWebview:level() return self end
function fakeWebview:deleteOnClose() return self end
function fakeWebview:html() return self end
function fakeWebview:show() return self end
function fakeWebview:bringToFront() return self end
function fakeWebview:hswindow() return nil end
function fakeWebview:delete() end
function fakeWebview:evaluateJavaScript(js) table.insert(evaljs_calls, js) end

local capturedCallback = nil

hs = {
  ipc = {},
  fnutils = { imap = function(t, fn) local r = {} for i, v in ipairs(t) do r[i] = fn(v) end return r end },
  json = { encode = stub_encode },
  execute = function(cmd) return "" end,
  hotkey = { bind = function() end },
  screen = { mainScreen = function() return { fullFrame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
  webview = {
    usercontent = { new = function(name) return { setCallback = function(self, cb) capturedCallback = cb end } end },
    new = function(frame, opts, ucc) return setmetatable({}, fakeWebview) end,
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  alert = { show = function() end },
  -- Deterministic stand-in for hs.base64.encode: the host must read the
  -- WHOLE file and hand its bytes to this, so echoing the byte count is
  -- enough to prove both without shipping a Lua base64 implementation.
  base64 = { encode = function(b) return "B64<" .. #b .. ">" end },
  task = {
    -- args is { "-c", "<the whole shell command>" }; record that command.
    new = function(path, doneCb, streamCb, args)
      return {
        start = function()
          table.insert(commands, tostring(args and args[2] or ""))
          doneCb(0, "data:image/jpeg;base64,ZZZZ", "")
        end,
      }
    end,
  },
}

local hostPath = os.getenv("HAMMERSPOON_HOST")
local ok, err = pcall(dofile, hostPath)
if not ok then
  error("failed to load " .. tostring(hostPath) .. " under stubs: " .. tostring(err))
end

OmamacMenu.open()
if not capturedCallback then
  error("openMenu() never registered a message callback via ucc:setCallback")
end

capturedCallback({ body = { action = "previews", kind = "theme" } })
capturedCallback({ body = { action = "previews", kind = "bg" } })
-- No kind at all must keep the historical meaning: wallpapers.
capturedCallback({ body = { action = "previews" } })

-- io.write, not print: under `nvim --headless` (helpers.sh's last-resort Lua
-- front-end) print() goes through Vim's message system, which merged two of
-- these long lines into one and made a passing assertion look like a failure.
-- io.write goes straight to stdout, byte for byte.
io.write("KIND_RESULT_START\n")
for i, c in ipairs(commands) do io.write("cmd" .. i .. "=" .. c .. "\n") end
for i, j in ipairs(evaljs_calls) do io.write("js" .. i .. "=" .. j .. "\n") end
io.write("KIND_RESULT_END\n")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify preview kind routing"
    return
  fi
  assert_eq 0 "$rc" "preview-kind harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  # Asserted against the whole captured blob with the NAME baked into every
  # pattern, so each check stays bound to the one message it is about — a
  # branch swap flips "--theme" onto the wrong name and fails, rather than
  # merely moving a matching substring elsewhere in the output.
  assert_contains "$out" "'preview' '--paths' '--theme'" \
    "kind=theme must invoke: omamac preview --paths --theme"
  local bg_calls; bg_calls=$(printf '%s\n' "$out" | grep -c "'preview' '--paths'\$")
  assert_eq 2 "$bg_calls" \
    "kind=bg and a kindless request must both invoke the wallpaper form: omamac preview --paths"
  # --paths on EVERY request: the image bytes must never travel through the
  # task pipe (see fileDataURI in the host), and the fan-out must happen
  # inside omamac rather than across hs.tasks.
  local n; n=$(printf '%s\n' "$out" | grep -c -- "--paths")
  assert_eq 3 "$n" "every request must ask for paths, not bytes"

  # And the kind must come back out to the page, or an arriving thumbnail
  # cannot be filed against the level that asked for it. The stub encoder
  # sorts keys, so kind and name land adjacent and can be asserted together
  # — a kind echoed against the wrong name will not match.
  # The stub task returns no lines, so nothing is pushed — the routing above
  # is what this test pins. Pushing is covered by the reassembly test below.
  assert_contains "$out" "omamac: no theme previews available" \
    "a level that yields nothing must say so rather than failing silently"
}

# THE regression test for the bug this whole path exists to avoid.
#
# hs.task loses output when many run at once. Measured against the real thing:
# 22 concurrent hs.tasks, each a trivial bash run that exited 0 with no
# stderr, delivered ZERO bytes of stdout to their Lua callbacks for 15 to 19
# of them, varying run to run, while Hammerspoon logged "hs.task received
# output data from an unknown task". On screen that was most of the coverflow
# stuck on flat placeholders.
#
# So the host must spawn exactly ONE task per level however many items the
# level holds. This drives a 22-item level and counts tasks — the previous
# per-item design scored 22 here.
test_one_task_per_level_regardless_of_item_count() {
  local harness="$TMPDIR_TEST/one_task_harness.lua"
  cat > "$harness" <<'LUAEOF'
package.loaded["hs.ipc"] = {}

local starts = 0
local commands = {}

local function stub_encode(t)
  if type(t) ~= "table" then error("expected table") end
  local parts = {}
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. k .. '":"' .. tostring(t[k]) .. '"' end
  return "{" .. table.concat(parts, ",") .. "}"
end

local fakeWebview = {}
fakeWebview.__index = fakeWebview
function fakeWebview:windowStyle() return self end
function fakeWebview:allowTextEntry() return self end
function fakeWebview:transparent() return self end
function fakeWebview:level() return self end
function fakeWebview:deleteOnClose() return self end
function fakeWebview:html() return self end
function fakeWebview:show() return self end
function fakeWebview:bringToFront() return self end
function fakeWebview:hswindow() return nil end
function fakeWebview:delete() end
function fakeWebview:evaluateJavaScript(js) end

local capturedCallback = nil

hs = {
  ipc = {},
  fnutils = { imap = function(t, fn) local r = {} for i, v in ipairs(t) do r[i] = fn(v) end return r end },
  json = { encode = stub_encode },
  base64 = { encode = function(b) return "B64<" .. #b .. ">" end },
  execute = function(cmd) return "" end,
  hotkey = { bind = function() end },
  screen = { mainScreen = function() return { fullFrame = function() return { x = 0, y = 0, w = 800, h = 600 } end } end },
  webview = {
    usercontent = { new = function(name) return { setCallback = function(self, cb) capturedCallback = cb end } end },
    new = function(frame, opts, ucc) return setmetatable({}, fakeWebview) end,
  },
  drawing = { windowLevels = { modalPanel = 1 } },
  alert = { show = function() end },
  task = {
    new = function(path, doneCb, streamCb, args)
      return {
        start = function()
          starts = starts + 1
          commands[#commands + 1] = tostring(args and args[2] or "")
          -- A 22-line response: one per theme, as omamac --paths emits.
          local lines = {}
          for i = 1, 22 do lines[#lines + 1] = "theme" .. i .. "\t/no/such/thumb" .. i .. ".jpg" end
          doneCb(0, table.concat(lines, "\n"), "")
        end,
      }
    end,
  },
}

local hostPath = os.getenv("HAMMERSPOON_HOST")
local ok, err = pcall(dofile, hostPath)
if not ok then error("failed to load host under stubs: " .. tostring(err)) end

OmamacMenu.open()
if not capturedCallback then error("openMenu() never registered a message callback") end

capturedCallback({ body = { action = "previews", kind = "theme" } })

io.write("ONE_TASK_START\n")
io.write("starts=" .. tostring(starts) .. "\n")
io.write("ONE_TASK_END\n")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify the task count"
    return
  fi
  assert_eq 0 "$rc" "one-task harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  local starts; starts=$(printf '%s\n' "$out" | sed -n 's/^starts=//p')
  assert_eq "1" "$starts" \
    "a 22-item level must cost exactly ONE hs.task — hs.task drops the stdout of most of its children when a couple of dozen run at once, silently and with exit status 0"
}

run_tests

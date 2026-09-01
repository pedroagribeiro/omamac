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
  assert_contains "$src" 'b.action == "preview"'
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
test_empty_preview_is_logged_and_still_pushed_to_the_page() {
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

-- Simulate the exact failure this bug report is about: omamac-preview
-- exited 0 with empty stdout (a truncated/missing/unreadable source file).
task_stdout = ""
capturedCallback({ body = { action = "preview", name = "1-alpha.jpg" } })

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

  assert_contains "$out" "omamac: preview empty for 1-alpha.jpg" \
    "an empty preview must be logged with the wallpaper's name, not dropped silently"

  local count; count=$(printf '%s\n' "$out" | sed -n 's/^evaljs_count=//p')
  assert_eq "1" "$count" "an empty preview must still be pushed to the page exactly once"

  local payload; payload=$(printf '%s\n' "$out" | sed -n 's/^evaljs_payload=//p')
  assert_contains "$payload" "omamacSetPreview"
  assert_contains "$payload" "1-alpha.jpg"
  assert_contains "$payload" '"uri":""' "the empty result must be pushed through as an empty uri, not swallowed"
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
capturedCallback({ body = { action = "preview", name = "1-alpha.jpg" } })

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

# Behavioural companion to the structural test above: proves the streaming
# callback's accumulated chunks actually reach the page, concatenated with
# whatever `done` also carries. A real large preview would arrive through
# many small streamed chunks (the pipe only ever holds ~64KB at a time) with
# `done`'s own stdout argument empty (the child already flushed everything
# via the stream) — this fakes exactly that shape.
test_runasync_concatenates_streamed_chunks_before_pushing_to_the_page() {
  local harness="$TMPDIR_TEST/streaming_accumulate_harness.lua"
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
  task = {
    -- Mimics a REAL large preview: the pipe only ever holds a chunk at a
    -- time, so the stream callback fires repeatedly while `done`'s own
    -- stdout argument is empty (everything already went through streaming).
    new = function(path, doneCb, streamCb, args)
      return {
        start = function()
          streamCb(nil, "data:image/jpeg;base64,AAAA", "")
          streamCb(nil, "BBBB", "")
          streamCb(nil, "CCCC", "")
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

capturedCallback({ body = { action = "preview", name = "big.jpg" } })

print("ACCUMULATE_RESULT_START")
print("evaljs_count=" .. tostring(#evaljs_calls))
print("evaljs_payload=" .. tostring(evaljs_calls[1] or "NONE"))
print("ACCUMULATE_RESULT_END")
LUAEOF

  local out rc
  out=$(OMAMAC_DIR="$OMAMAC_ROOT" HAMMERSPOON_HOST="$HOST" lua_run "$harness" 2>&1); rc=$?
  if [ "$rc" -eq 127 ]; then
    fail "no executing Lua interpreter available — cannot verify chunk accumulation"
    return
  fi
  assert_eq 0 "$rc" "accumulate harness must run cleanly, got: $out"
  [ "$rc" -eq 0 ] || return

  local count; count=$(printf '%s\n' "$out" | sed -n 's/^evaljs_count=//p')
  assert_eq "1" "$count" "a streamed preview must still be pushed to the page exactly once"

  local payload; payload=$(printf '%s\n' "$out" | sed -n 's/^evaljs_payload=//p')
  assert_contains "$payload" "data:image/jpeg;base64,AAAABBBBCCCC" \
    "chunks streamed across multiple hs.task.new callback invocations must be concatenated in order, not dropped or reordered"
}

run_tests

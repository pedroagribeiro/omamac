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

run_tests

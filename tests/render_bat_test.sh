#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
THEME="$OMAMAC_ROOT/tests/fixtures/dark"

# Extract the foreground actually bound to a named scope. A bare
# `assert_contains "<string>#9ece6a</string>"` proves only that the colour appears
# SOMEWHERE — swapping two scopes' colours leaves every such assertion green, and a
# scope whose colour coincides with another key's is satisfied vacuously.
scope_colour() { # <file> <scope-name>
  awk -v n="$2" '
    $0 ~ "<string>" n "</string>" { found = 1 }
    found && /<key>foreground<\/key>/ {
      match($0, /#[0-9a-f]{6}/); print substr($0, RSTART, RLENGTH); exit
    }
  ' "$1"
}

test_writes_tmtheme_with_colors() {
  local root="$TMPDIR_TEST/t1"
  export OMAMAC_BAT="true"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  local out; out=$(cat "$root/bat/themes/omamac.tmTheme")
  # One assertion per distinct source colour key the renderer consumes (11 of
  # them), not per emitted line. Sampling would let a mutant that swaps colors pass.
  # selection_background aliases to `selection`; color8 aliases to `muted` —
  # tokyo-night's real colors.toml has neither key literally.
  assert_contains "$out" '<key>background</key><string>#1a1b26</string>'    # background
  assert_contains "$out" '<key>foreground</key><string>#a9b1d6</string>'    # foreground
  assert_contains "$out" '<key>caret</key><string>#c0caf5</string>'         # cursor
  assert_contains "$out" '<key>selection</key><string>#292e42</string>'     # selection_background
  assert_contains "$out" '<string>#414868</string>'                         # color8
  assert_contains "$out" '<string>#9ece6a</string>'                         # color2
  assert_contains "$out" '<string>#ad8ee6</string>'                         # color5
  assert_contains "$out" '<string>#449dab</string>'                         # color6
  assert_contains "$out" '<string>#e0af68</string>'                         # color3
  assert_contains "$out" '<string>#7aa2f7</string>'                         # color4
  assert_contains "$out" '<string>#f7768e</string>'                         # color1
}

test_tmtheme_is_valid_plist() {
  local root="$TMPDIR_TEST/t2"
  export OMAMAC_BAT="true"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  plutil -lint "$root/bat/themes/omamac.tmTheme" >/dev/null || fail "invalid plist"
}

test_rebuilds_bat_cache() {
  local root="$TMPDIR_TEST/t3"
  cat > "$TMPDIR_TEST/bat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$BAT_LOG"
EOF
  chmod +x "$TMPDIR_TEST/bat"
  export OMAMAC_BAT="$TMPDIR_TEST/bat" BAT_LOG="$TMPDIR_TEST/bat.log"
  : > "$BAT_LOG"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  assert_contains "$(cat "$BAT_LOG")" "cache"
}

test_missing_colors_toml_exits_nonzero() {
  export OMAMAC_BAT="true"
  mkdir -p "$TMPDIR_TEST/empty"
  local rc; "$OMAMAC_ROOT/render/bat" "$TMPDIR_TEST/empty" "$TMPDIR_TEST/t4" >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc" "a theme dir with no colors.toml must signal failure"
}

test_missing_colour_key_warns_and_stays_valid_plist() {
  export OMAMAC_BAT="true"
  local root="$TMPDIR_TEST/t5" partial="$TMPDIR_TEST/partial-bat"
  mkdir -p "$partial"
  # color1 resolves via omamac_alias to `red`; stripping `red` (not a
  # literal `color1` line, which doesn't exist upstream) is what makes it
  # missing. The trailing space excludes `bright_red`.
  grep -v '^red ' "$THEME/colors.toml" > "$partial/colors.toml"
  local err; err=$("$OMAMAC_ROOT/render/bat" "$partial" "$root" 2>&1)
  assert_contains "$err" "missing colour 'color1'"
  # A bare "#" is still valid XML, so lint alone cannot catch it — assert the
  # fallback landed, then confirm the document is still well-formed.
  assert_contains "$(cat "$root/bat/themes/omamac.tmTheme")" "#000000"
  plutil -lint "$root/bat/themes/omamac.tmTheme" >/dev/null || fail "invalid plist"
}

test_each_scope_binds_its_own_colour() {
  local root="$TMPDIR_TEST/t6"
  export OMAMAC_BAT="true"
  "$OMAMAC_ROOT/render/bat" "$THEME" "$root"
  local f="$root/bat/themes/omamac.tmTheme"
  assert_eq "#414868" "$(scope_colour "$f" Comment)"   # color8 (alias: muted)
  assert_eq "#9ece6a" "$(scope_colour "$f" String)"    # color2
  assert_eq "#ad8ee6" "$(scope_colour "$f" Number)"    # color5
  assert_eq "#449dab" "$(scope_colour "$f" Constant)"  # color6
  assert_eq "#ad8ee6" "$(scope_colour "$f" Keyword)"   # color5
  assert_eq "#ad8ee6" "$(scope_colour "$f" Storage)"   # color5
  assert_eq "#e0af68" "$(scope_colour "$f" Type)"      # color3
  assert_eq "#7aa2f7" "$(scope_colour "$f" Function)"  # color4
  assert_eq "#a9b1d6" "$(scope_colour "$f" Variable)"  # foreground
  assert_eq "#f7768e" "$(scope_colour "$f" Invalid)"   # color1
}

run_tests

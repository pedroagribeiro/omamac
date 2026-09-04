#!/usr/bin/env bash
# The installer, with brew and git stubbed. Nothing here installs anything,
# clones anything, or writes outside the test's own temp HOME.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

INSTALL="$OMAMAC_ROOT/install"

setup_install() {
  export OMAMAC_INSTALL_DIR="$TMPDIR_TEST/share/omamac"
  export OMAMAC_BIN_DIR="$TMPDIR_TEST/bin"
  export OMAMAC_HS_INIT="$TMPDIR_TEST/hammerspoon/init.lua"
  export BREW_LOG="$TMPDIR_TEST/brew.log"
  export GIT_LOG="$TMPDIR_TEST/git.log"

  # brew that records what it was asked to do and claims nothing is installed,
  # so the install paths are the ones exercised.
  cat > "$TMPDIR_TEST/brew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_LOG"
case "$1" in list) exit 1 ;; esac
exit 0
STUB
  chmod +x "$TMPDIR_TEST/brew"
  export OMAMAC_BREW="$TMPDIR_TEST/brew"

  # git that records, and "clones" by copying the real checkout — so the script
  # afterwards finds a tree with a real bin/omamac in it.
  cat > "$TMPDIR_TEST/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GIT_LOG"
if [ "\$1" = "clone" ]; then
  dest="\${@: -1}"
  mkdir -p "\$dest"
  cp -R "$OMAMAC_ROOT/bin" "$OMAMAC_ROOT/hammerspoon" "\$dest/"
  mkdir -p "\$dest/.git"
fi
exit 0
STUB
  chmod +x "$TMPDIR_TEST/git"
  export OMAMAC_GIT="$TMPDIR_TEST/git"
}

# Run the installer the way a checkout does — BASH_SOURCE points at the real
# file, so it installs from here rather than cloning.
run_install() { bash "$INSTALL" "$@" 2>&1; }

# ---------------------------------------------------------------- the link --

test_it_links_the_cli_onto_path() {
  setup_install
  run_install >/dev/null
  [ -L "$OMAMAC_BIN_DIR/omamac" ] || fail "omamac must be symlinked into the bin dir"
  assert_eq "$OMAMAC_ROOT/bin/omamac" "$(readlink "$OMAMAC_BIN_DIR/omamac")" \
    "the symlink must point at this checkout's bin/omamac"
}

test_it_is_idempotent() {
  setup_install
  run_install >/dev/null
  local first; first=$(readlink "$OMAMAC_BIN_DIR/omamac")
  local init_first; init_first=$(cat "$OMAMAC_HS_INIT")
  run_install >/dev/null
  assert_eq "$first" "$(readlink "$OMAMAC_BIN_DIR/omamac")" "re-running must not change the link"
  assert_eq "$init_first" "$(cat "$OMAMAC_HS_INIT")" "re-running must not change init.lua"
}

# Installing somewhere the shell will not look is the most likely way this ends
# in "command not found" with nothing obviously broken.
test_it_warns_when_the_bin_dir_is_not_on_path() {
  setup_install
  local out; out=$(PATH="/usr/bin:/bin" run_install)
  assert_contains "$out" "not on your PATH"
}

test_it_stays_quiet_when_the_bin_dir_is_on_path() {
  setup_install
  local out; out=$(PATH="${OMAMAC_BIN_DIR}:${PATH}" run_install)
  case "$out" in *"not on your PATH"*) fail "must not warn when the dir IS on PATH" ;; esac
}

# --------------------------------------------------------------- init.lua --

test_it_writes_an_init_lua_when_there_is_none() {
  setup_install
  run_install >/dev/null
  [ -f "$OMAMAC_HS_INIT" ] || fail "init.lua must be written"
  assert_contains "$(cat "$OMAMAC_HS_INIT")" "OMAMAC_DIR"
  assert_contains "$(cat "$OMAMAC_HS_INIT")" "hammerspoon/omamac.lua"
}

# Someone else's init.lua is theirs. Overwriting it would silently delete
# whatever else they drive from Hammerspoon.
test_it_refuses_to_overwrite_an_init_lua_it_did_not_write() {
  setup_install
  mkdir -p "$(dirname "$OMAMAC_HS_INIT")"
  printf 'hs.alert.show("mine")\n' > "$OMAMAC_HS_INIT"
  local out; out=$(run_install)
  assert_eq 'hs.alert.show("mine")' "$(cat "$OMAMAC_HS_INIT")" "an existing init.lua must be left alone"
  assert_contains "$out" "leaving it alone"
  # And it must say what to add, or the user is stuck.
  assert_contains "$out" "dofile(OMAMAC_DIR"
}

test_it_does_rewrite_an_init_lua_it_wrote_itself() {
  setup_install
  run_install >/dev/null
  printf '\n-- a later edit\n' >> "$OMAMAC_HS_INIT"
  run_install >/dev/null
  case "$(cat "$OMAMAC_HS_INIT")" in
    *"a later edit"*) fail "its own init.lua must be regenerated, not appended to" ;;
  esac
  assert_contains "$(cat "$OMAMAC_HS_INIT")" "OMAMAC_DIR"
}

# A dotfiles repo makes ~/.hammerspoon/init.lua a SYMLINK into the repo. The
# previous version of this script tested `[ -e ] && [ ! -L ]`, so it wrote
# straight THROUGH that symlink and clobbered the real file at the far end.
test_a_symlinked_init_lua_is_not_written_through() {
  setup_install
  local real="$TMPDIR_TEST/dotfiles/init.lua"
  mkdir -p "$(dirname "$real")" "$(dirname "$OMAMAC_HS_INIT")"
  printf 'hs.alert.show("from my dotfiles")\n' > "$real"
  ln -s "$real" "$OMAMAC_HS_INIT"
  run_install >/dev/null
  assert_eq 'hs.alert.show("from my dotfiles")' "$(cat "$real")" \
    "the file behind the symlink must be untouched"
  [ -L "$OMAMAC_HS_INIT" ] || fail "the symlink itself must survive"
}

# ------------------------------------------------------------ dependencies --

test_it_installs_jq_and_hammerspoon() {
  setup_install
  run_install >/dev/null
  assert_contains "$(cat "$BREW_LOG")" "install jq"
  assert_contains "$(cat "$BREW_LOG")" "install --cask hammerspoon"
}

test_it_refuses_to_run_without_homebrew_and_says_why() {
  setup_install
  export OMAMAC_BREW="$TMPDIR_TEST/definitely-not-brew"
  local out; out=$(run_install); local rc=$?
  [ "$rc" -ne 0 ] || fail "a missing Homebrew must exit non-zero"
  assert_contains "$out" "Homebrew is required"
  # It must not install Homebrew itself — a piped script asking for a password
  # and chowning directories is exactly what makes curl|bash untrustworthy.
  assert_contains "$out" "not run for you"
  [ ! -e "$OMAMAC_BIN_DIR/omamac" ] || fail "nothing must be linked when the check fails"
}

# ------------------------------------------------------------ curl | bash --

# Piped, BASH_SOURCE names no file with bin/omamac beside it, so there is
# nothing to install FROM and the script has to fetch one.
test_piped_into_bash_it_clones_first() {
  setup_install
  local out; out=$(cat "$INSTALL" | bash 2>&1)
  assert_contains "$out" "Cloning omamac"
  assert_contains "$(cat "$GIT_LOG")" "clone"
  [ -L "$OMAMAC_BIN_DIR/omamac" ] || fail "it must still end up linked"
  assert_eq "$OMAMAC_INSTALL_DIR/bin/omamac" "$(readlink "$OMAMAC_BIN_DIR/omamac")" \
    "the link must point into the freshly cloned tree"
}

test_piped_a_second_time_it_updates_instead_of_recloning() {
  setup_install
  cat "$INSTALL" | bash >/dev/null 2>&1
  : > "$GIT_LOG"
  local out; out=$(cat "$INSTALL" | bash 2>&1)
  assert_contains "$out" "Updating"
  assert_contains "$(cat "$GIT_LOG")" "pull"
  case "$(cat "$GIT_LOG")" in *clone*) fail "an existing checkout must be pulled, not re-cloned" ;; esac
}

# ------------------------------------------------------------- uninstall --

test_uninstall_removes_the_link_and_keeps_your_data() {
  setup_install
  run_install >/dev/null
  local out; out=$(run_install --uninstall)
  [ ! -e "$OMAMAC_BIN_DIR/omamac" ] || fail "--uninstall must remove the symlink"
  # Your themes and choices are not the installer's to delete.
  assert_contains "$out" "state/omamac"
  assert_contains "$out" "Left in place"
}

test_an_unknown_flag_is_refused_without_doing_anything() {
  setup_install
  run_install --wat >/dev/null 2>&1 && fail "an unknown flag must exit non-zero"
  [ ! -e "$OMAMAC_BIN_DIR/omamac" ] || fail "a refused call must install nothing"
  [ ! -f "$BREW_LOG" ] || fail "a refused call must not reach brew"
}

run_tests

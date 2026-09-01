#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

setup_bg() {
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true"
  cat > "$TMPDIR_TEST/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OSA_LOG"
EOF
  chmod +x "$TMPDIR_TEST/osascript"
  export OMAMAC_OSASCRIPT="$TMPDIR_TEST/osascript" OSA_LOG="$TMPDIR_TEST/osa.log"
  : > "$OSA_LOG"
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  : > "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

test_list_returns_cached_basenames_sorted() {
  setup_bg
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
}

test_set_records_absolute_path_and_calls_osascript() {
  setup_bg
  "$OMAMAC_BIN" bg 2-beta.jpg >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "2-beta.jpg"
  assert_contains "$(cat "$OSA_LOG")" "set picture to"
}

test_next_cycles_and_wraps() {
  setup_bg
  "$OMAMAC_BIN" bg 1-alpha.jpg >/dev/null 2>&1
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "2-beta.jpg"
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "1-alpha.jpg"
}

test_next_with_nothing_set_picks_the_first() {
  setup_bg
  "$OMAMAC_BIN" bg --next >/dev/null 2>&1
  assert_contains "$("$OMAMAC_BIN" bg --current)" "1-alpha.jpg"
}

test_unknown_wallpaper_exits_1() {
  setup_bg
  local rc; "$OMAMAC_BIN" bg nope.jpg >/dev/null 2>&1; rc=$?
  assert_eq 1 "$rc"
}

# --- Step 5: on-demand fetch, exercised with no network ---
#
# The brief's Step 5 sample lists a theme's upstream backgrounds via the GitHub
# contents API (a hardcoded https://api.github.com URL). That call cannot be
# pointed at a fixture for tests and is rate-limited at runtime — and it turns
# out upstream ships no such index of its own anyway. So the file list is
# vendored instead: tools/sync-themes (Task 12) writes a plain-text
# backgrounds.index into each theme's directory at vendor time, when it already
# has GitHub API access. bg_fetch reads that local index — no network — and
# only the per-file downloads go over OMAMAC_FETCH, against a pinned upstream
# revision. In tests, OMAMAC_OMARCHY_RAW/OMAMAC_OMARCHY_REV point at a local
# file:// fixture tree, so even the download leg never touches the network;
# curl itself is never stubbed, it just never leaves the filesystem.
setup_bg_fetch() {
  # Every test sharing this suite's shell runs in the SAME process (no
  # subshell — see helpers.sh's run_tests), so an `export` in one test would
  # otherwise leak into the next. Reset OMAMAC_FETCH here so a stub set by
  # one test (e.g. the broken-fetch stub below) can never bleed into another.
  unset OMAMAC_FETCH
  export OMAMAC_THEMES_DIR="$TMPDIR_TEST/themes"
  mkdir -p "$OMAMAC_THEMES_DIR/tokyo-night"
  cp "$OMAMAC_ROOT/tests/fixtures/dark/colors.toml" "$OMAMAC_THEMES_DIR/tokyo-night/"
  printf '1-alpha.jpg\n2-beta.jpg\n' > "$OMAMAC_THEMES_DIR/tokyo-night/backgrounds.index"
  export OMAMAC_CONFIG_ROOT="$TMPDIR_TEST/config"
  export OMAMAC_KILL="true" OMAMAC_OSASCRIPT="true"
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/omarchy"
  export OMAMAC_OMARCHY_REV="rev"
  printf 'tokyo-night\n' > "$OMAMAC_STATE/theme.name"
}

test_list_fetches_upstream_when_cache_is_empty() {
  setup_bg_fetch
  # Cache starts empty: nothing under $OMAMAC_CACHE/backgrounds/tokyo-night yet.
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
  assert_eq "hello-alpha" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg")"
  assert_eq "hello-beta" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg")"
}

test_list_does_not_redownload_an_already_cached_file() {
  setup_bg_fetch
  # Both index entries are already cached with content that differs from the
  # fixture's — if bg_fetch re-fetched them anyway, this content would be
  # clobbered with the fixture's "hello-alpha"/"hello-beta".
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  printf 'already-here-alpha' > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  printf 'already-here-beta' > "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg"
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
  assert_eq "already-here-alpha" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg")"
  assert_eq "already-here-beta" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg")"
}

test_list_with_no_backgrounds_index_warns_and_succeeds() {
  setup_bg_fetch
  rm -f "$OMAMAC_THEMES_DIR/tokyo-night/backgrounds.index"
  local out rc
  out=$("$OMAMAC_BIN" bg --list 2>&1); rc=$?
  assert_eq 0 "$rc" "a missing backgrounds.index must not fail the command"
  assert_eq "" "$("$OMAMAC_BIN" bg --list 2>/dev/null)"
  assert_contains "$out" "no backgrounds.index"
}

# An interrupted fetch (Ctrl-C, dropped network, a closed laptop lid) must not
# permanently strand the cache. bg_fetch has to decide per FILE, not per
# directory: a non-empty cache with only 1 of 2 index entries present must
# still fetch the missing one. Pre-fixture-check: this test is RED against the
# prior `[ -z "$(ls -A "$dir")" ] || return 0` directory-level guard, because
# that guard sees the non-empty directory and returns immediately, so
# 2-beta.jpg never arrives — that is the whole point of the fix.
test_fetch_resumes_a_partial_cache() {
  setup_bg_fetch
  mkdir -p "$OMAMAC_CACHE/backgrounds/tokyo-night"
  printf 'already-here-alpha' > "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
  # The pre-existing file must survive untouched...
  assert_eq "already-here-alpha" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg")"
  # ...while the missing one is the one that gets fetched.
  assert_eq "hello-beta" "$(cat "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg")"
}

test_failed_download_leaves_no_stub() {
  setup_bg_fetch
  export OMAMAC_OMARCHY_RAW="file://$OMAMAC_ROOT/tests/fixtures/does-not-exist"
  local out rc
  out=$("$OMAMAC_BIN" bg --list 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed per-file download must not fail the command"
  assert_eq "no" "$([ -f "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg" ] && echo yes || echo no)"
  assert_eq "no" "$([ -f "$OMAMAC_CACHE/backgrounds/tokyo-night/2-beta.jpg" ] && echo yes || echo no)"
  assert_contains "$out" "could not fetch"
}

# The test above (a missing file:// source) never leaves a stub in the first
# place, because curl's local file:// reader fails before it opens -o's
# destination for writing — so it cannot, on its own, prove the `rm -f`
# cleanup line in bg_fetch actually does anything. Verified empirically:
#   curl -fsSL -o dest.jpg file:///no/such/path   # dest.jpg is never created
# The bug the `rm -f` guards against is real for plain HTTP curl, though:
# `curl -f -o file url` is documented to sometimes create an empty/partial
# `file` before it has read enough of the response to know the request
# failed. A stub $OMAMAC_FETCH reproduces exactly that shape locally (no
# network involved) so the cleanup line has a test that would actually go red
# if it were deleted.
test_failed_download_via_stub_fetch_leaves_no_stub_file() {
  setup_bg_fetch
  cat > "$TMPDIR_TEST/broken-fetch" <<'FETCHEOF'
#!/usr/bin/env bash
# Simulates a curl that creates its -o destination before discovering the
# request failed (the documented curl -f -o behavior on an HTTP error).
dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$dest" ] && printf 'partial' > "$dest"
exit 1
FETCHEOF
  chmod +x "$TMPDIR_TEST/broken-fetch"
  export OMAMAC_FETCH="$TMPDIR_TEST/broken-fetch"
  local out rc
  out=$("$OMAMAC_BIN" bg --list 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed per-file download must not fail the command"
  assert_eq "no" "$([ -f "$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg" ] && echo yes || echo no)" \
    "a stub left by a failed download must be cleaned up, or it is cached forever"
  assert_contains "$out" "could not fetch"
}

# --- Atomic download: a wallpaper mid-download must never be visible under
# its real name --- see the coverflow-picker bug report: the perf work runs
# uncached fetches detached, so a SECOND, concurrent `bg --list` (e.g. from
# opening the menu) can run while a fetch for the very same file is still in
# flight. If bg_fetch writes straight to the final name, that second caller
# sees a truncated file that IS the real name, offers it in the picker, and
# the preview then fails on the truncated bytes.
#
# The stub below is a curl stand-in keyed by a per-URL mkdir lock: the first
# invocation for a given background name "wins" the lock, writes partial
# bytes to whatever path bg_fetch handed it via -o, signals $FETCH_MARKER,
# and then blocks on $FETCH_RELEASE before failing — simulating a slow
# in-flight download. Any OTHER concurrent invocation for the SAME name
# (i.e. a second, redundant fetch attempt racing the first) loses the lock
# and fails immediately rather than blocking, so a concurrent observer that
# itself calls through bg_fetch can never deadlock against the first,
# regardless of which code path (direct-to-final vs atomic-via-temp) is
# under test.
setup_bg_fetch_slow() {
  setup_bg_fetch
  # A single index entry: with two entries, the observer's own bg_fetch call
  # (see below) would still need to attempt-and-lose the lock for the SECOND
  # entry too, since neither invocation has cached it yet — needless noise
  # against the one property under test here.
  printf '1-alpha.jpg\n' > "$OMAMAC_THEMES_DIR/tokyo-night/backgrounds.index"
  export FETCH_LOCKROOT="$TMPDIR_TEST/locks" FETCH_MARKER="$TMPDIR_TEST/fetch-started" \
         FETCH_RELEASE="$TMPDIR_TEST/fetch-release"
  mkdir -p "$FETCH_LOCKROOT"
  rm -f "$FETCH_MARKER" "$FETCH_RELEASE"
  cat > "$TMPDIR_TEST/slow-fetch" <<'FETCHEOF'
#!/usr/bin/env bash
set -u
dest="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
lockdir="$FETCH_LOCKROOT/$(basename "$url")"
if ! mkdir "$lockdir" 2>/dev/null; then
  # Another invocation is already "downloading" this exact name — fail fast
  # instead of blocking, so a concurrent duplicate fetch attempt can never
  # deadlock this test.
  exit 1
fi
[ -n "$dest" ] && printf 'partial-bytes' > "$dest"
touch "$FETCH_MARKER"
while [ ! -f "$FETCH_RELEASE" ]; do sleep 0.05; done
exit 1
FETCHEOF
  chmod +x "$TMPDIR_TEST/slow-fetch"
  export OMAMAC_FETCH="$TMPDIR_TEST/slow-fetch"
}

test_partial_download_is_never_visible_under_its_final_name_while_in_flight() {
  setup_bg_fetch_slow

  "$OMAMAC_BIN" bg --list > "$TMPDIR_TEST/list-writer.out" 2>&1 &
  local writer_pid=$!

  local waited=0
  while [ ! -f "$FETCH_MARKER" ] && [ "$waited" -lt 100 ]; do
    waited=$((waited + 1)); sleep 0.05
  done
  if [ ! -f "$FETCH_MARKER" ]; then
    fail "fetch stub never signalled that partial bytes were written"
    touch "$FETCH_RELEASE"; wait "$writer_pid" 2>/dev/null
    return
  fi

  # The download is now "in flight": partial bytes are on disk somewhere,
  # but the fetch has neither succeeded nor failed yet.
  local final="$OMAMAC_CACHE/backgrounds/tokyo-night/1-alpha.jpg"
  assert_eq "no" "$([ -e "$final" ] && echo yes || echo no)" \
    "the real filename must not exist until the download actually finishes"
  local stray; stray=$(find "$OMAMAC_CACHE/backgrounds/tokyo-night" -maxdepth 1 -name '.*part*' 2>/dev/null)
  assert_contains "$stray" "part" "an in-flight download must be visible only under a hidden temp sibling"

  # A concurrent, independent `bg --list` call — e.g. the menu opening while
  # the detached fetch above is still running — must not offer the
  # in-flight wallpaper either. This is the literal RED/GREEN case: on the
  # direct-to-final code, bg_fetch's own `[ -f "${dir}/${n}" ]` check sees
  # the writer's partial file already sitting at the real name and skips
  # re-fetching it entirely, so it shows up in this list immediately.
  local list_during; list_during=$("$OMAMAC_BIN" bg --list 2>/dev/null)
  assert_eq "" "$list_during" "bg --list must not offer a wallpaper that is still downloading"

  touch "$FETCH_RELEASE"
  wait "$writer_pid" 2>/dev/null

  # Once the (failed) download settles, nothing — neither the real name nor
  # a leftover temp file — must remain.
  assert_eq "no" "$([ -e "$final" ] && echo yes || echo no)" "a failed download must not leave the real name behind"
  stray=$(find "$OMAMAC_CACHE/backgrounds/tokyo-night" -maxdepth 1 -name '.*part*' 2>/dev/null)
  assert_eq "" "$stray" "a failed download must not leave a temp file behind"
}

# bg_list must ignore any leftover .part file regardless of how it got
# there (e.g. a download killed with SIGKILL, which skips bg_fetch's own
# `rm -f` cleanup entirely) — not just files this run's bg_fetch created and
# cleaned up itself. This fixture deliberately does NOT use a leading dot,
# so the assertion cannot pass merely because plain `ls -1` already hides
# dotfiles by default — it must be bg_list's own filter doing the work.
test_bg_list_ignores_leftover_part_files() {
  setup_bg
  touch "$OMAMAC_CACHE/backgrounds/tokyo-night/3-gamma.jpg.part"
  assert_eq "1-alpha.jpg
2-beta.jpg" "$("$OMAMAC_BIN" bg --list)"
}

run_tests

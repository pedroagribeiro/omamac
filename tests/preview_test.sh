#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A stub sips that "converts" by copying its input (the arg right before
# --out) to the --out path. Parses --out out of the argument list rather
# than assuming a fixed position.
setup_sips_ok() {
  cat > "$TMPDIR_TEST/sips-ok" <<'EOF'
#!/usr/bin/env bash
src=""
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then
    out="$a"
  fi
  prev="$a"
done
# The source path is the argument immediately before --out.
prev=""
for a in "$@"; do
  if [ "$a" = "--out" ]; then
    src="$prev"
  fi
  prev="$a"
done
cp "$src" "$out"
EOF
  chmod +x "$TMPDIR_TEST/sips-ok"
  export OMAMAC_SIPS="$TMPDIR_TEST/sips-ok"
}

# A stub sips that reproduces the real tool's failure mode: it creates the
# --out file (a zero-byte stub) and THEN fails, exit 1.
setup_sips_fails_after_creating_out() {
  cat > "$TMPDIR_TEST/sips-fail" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then
    out="$a"
  fi
  prev="$a"
done
: > "$out"
exit 1
EOF
  chmod +x "$TMPDIR_TEST/sips-fail"
  export OMAMAC_SIPS="$TMPDIR_TEST/sips-fail"
}

setup_preview_env() {
  printf 'gruvbox\n' > "$OMAMAC_STATE/theme.name"
  mkdir -p "$OMAMAC_CACHE/backgrounds/gruvbox"
  printf 'fake-jpeg-bytes\n' > "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg"
}

test_no_arguments_exits_cleanly() {
  setup_preview_env
  local out rc
  out=$("$OMAMAC_BIN" preview 2>&1); rc=$?
  assert_eq 0 "$rc" "no-args call must exit 0, not crash"
  assert_eq "" "$out"
}

test_unknown_basename_exits_cleanly() {
  setup_preview_env
  local out rc
  out=$("$OMAMAC_BIN" preview does-not-exist.jpg 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

test_no_current_theme_exits_cleanly() {
  # No theme.name written at all.
  mkdir -p "$OMAMAC_CACHE/backgrounds/gruvbox"
  printf 'fake-jpeg-bytes\n' > "$OMAMAC_CACHE/backgrounds/gruvbox/1-alpha.jpg"
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc"
  assert_eq "" "$out"
}

test_successful_conversion_emits_data_uri_and_caches_thumb() {
  setup_preview_env
  setup_sips_ok
  local out
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg)
  assert_contains "$out" "data:image/jpeg;base64,"
  [ -s "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.jpg" ] || fail "thumbnail was not cached"
}

test_failed_conversion_does_not_poison_the_cache() {
  setup_preview_env
  setup_sips_fails_after_creating_out
  local out rc
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg 2>&1); rc=$?
  assert_eq 0 "$rc" "a failed conversion must still exit 0 (quiet degradation)"
  assert_eq "" "$out" "a failed conversion must produce no output, not a malformed data URI"
  [ -f "$OMAMAC_CACHE/thumbs/gruvbox/1-alpha.jpg.jpg" ] && \
    fail "a failed conversion must not leave a stub thumbnail behind"

  # And recovery: a subsequent call with a working sips must succeed rather
  # than being permanently served the poisoned (zero-byte) cache entry. A
  # merely-present "data:image/jpeg;base64," prefix isn't enough to prove
  # this — base64 of the empty poisoned stub also yields that prefix with
  # nothing after it — so require an actual non-empty payload.
  setup_sips_ok
  out=$("$OMAMAC_BIN" preview 1-alpha.jpg)
  assert_contains "$out" "data:image/jpeg;base64,"
  local payload="${out#data:image/jpeg;base64,}"
  [ -n "$payload" ] || fail "recovery must serve a real thumbnail, not the poisoned empty stub"
}

run_tests

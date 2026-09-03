#!/usr/bin/env bash
# Screenshots and recordings, with screencapture stubbed — nothing here touches
# the real screen, the real clipboard, or the user's Pictures/Movies.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A stub that behaves the way screencapture actually does, which is the only
# reason these tests mean anything:
#   - the file is the LAST argument
#   - it exits 0 for a cancelled interactive capture and writes nothing, so
#     the exit status cannot distinguish success from cancel
#   - -v runs until signalled and writes NOTHING until then: the output file
#     appears only when the recording is finalised. An earlier stub created it
#     immediately, which is why the five-second start stall it caused was
#     invisible here and only turned up against the real binary.
setup_capture() {
  # The grace period the recorder waits to prove it survived. It cannot be cut
  # much below the real 0.5s here: the stub is a Python script, and measured
  # interpreter startup on this machine lands between 0.1s and 0.5s. Set it
  # shorter and the checks run before the stub exists — its arguments unlogged,
  # and a SIGINT arriving before signal.signal() lost to the SIG_IGN a
  # backgrounded child inherits. The real screencapture is a native binary and
  # has no such startup.
  export OMAMAC_RECORD_GRACE=0.6
  export OMAMAC_SCREENSHOT_DIR="$TMPDIR_TEST/shots"
  export OMAMAC_SCREENRECORD_DIR="$TMPDIR_TEST/movies"
  export CAP_LOG="$TMPDIR_TEST/capture.args"
  export CAP_CANCEL=""
  rm -f "$CAP_LOG"

  # Python, not bash. A recorder is started with `&` from a non-interactive
  # shell, and POSIX hands such children SIGINT already ignored — bash then
  # cannot trap it at all, so a bash stub could never finalise and every
  # recording test would fail for a reason the product does not have. The real
  # screencapture installs its own SIGINT handler and overrides that
  # inheritance (verified against the real binary); Python's signal.signal does
  # the same, so the stub behaves like the thing it stands in for. A stop sent
  # as anything but INT still kills it without finalising, which is what keeps
  # this able to catch the wrong signal.
  cat > "$TMPDIR_TEST/screencapture" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys, time
args = sys.argv[1:]
with open(os.environ["CAP_LOG"], "a") as f:
    f.write(" ".join(args) + "\n")
if os.environ.get("CAP_CANCEL"):
    sys.exit(0)
out = args[-1]
if "-v" in args:
    def finalise(signum, frame):
        with open(out, "w") as f:
            f.write("mdatmoov")
        sys.exit(0)
    signal.signal(signal.SIGINT, finalise)
    # Deliberately no file yet — see the note above.
    while True:
        time.sleep(0.05)
else:
    with open(out, "w") as f:
        f.write("PNG")
STUB
  chmod +x "$TMPDIR_TEST/screencapture"
  export OMAMAC_SCREENCAPTURE="$TMPDIR_TEST/screencapture"

  # The path is baked in at write time: TMPDIR_TEST is not exported, so a stub
  # that referenced it would silently write nothing and the clipboard
  # assertions would pass or fail for the wrong reason.
  export OSA_LOG="$TMPDIR_TEST/osascript.args"
  cat > "$TMPDIR_TEST/osascript" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMPDIR_TEST/osascript.args"
STUB
  chmod +x "$TMPDIR_TEST/osascript"
  export OMAMAC_OSASCRIPT="$TMPDIR_TEST/osascript"
}

# ---------------------------------------------------------------- geometry --

# The picker speaks slurp's "X,Y WxH"; screencapture -R wants "x,y,w,h". This
# is the one pure piece of the whole feature, and a silent mis-order would
# capture a rectangle somewhere else entirely rather than fail.
test_region_becomes_screencaptures_rect_in_the_right_order() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "12,34 560x480" >/dev/null
  assert_contains "$(cat "$CAP_LOG")" "-R 12,34,560,480"
}

# Monitors left of the main display have negative origins; upstream's own regex
# allows them, and a rect that silently refuses them cannot capture anything on
# that screen.
test_region_accepts_negative_origins() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "-1920,-200 800x600" >/dev/null
  assert_contains "$(cat "$CAP_LOG")" "-R -1920,-200,800,600"
}

test_a_malformed_region_is_refused_without_capturing() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "not a region" >/dev/null 2>&1
  [ $? -ne 0 ] || fail "a malformed region must exit non-zero"
  [ ! -f "$CAP_LOG" ] || fail "a malformed region must not reach screencapture"
}

test_no_region_falls_back_to_the_interactive_picker() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot >/dev/null
  assert_contains "$(cat "$CAP_LOG")" "-i"
}

# ------------------------------------------------------------- screenshots --

test_screenshot_lands_in_the_screenshot_dir_with_omarchys_name() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" >/dev/null
  local f; f=$(find "$OMAMAC_SCREENSHOT_DIR" -name 'screenshot-*.png' | head -1)
  [ -n "$f" ] || fail "no screenshot written"
  # Upstream: screenshot-%Y-%m-%d_%H-%M-%S.png
  basename "$f" | grep -qE '^screenshot-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.png$' \
    || fail "name does not follow Omarchy's screenshot-<date>_<time>.png"
}

test_the_screenshot_dir_is_created_when_missing() {
  setup_capture
  [ ! -d "$OMAMAC_SCREENSHOT_DIR" ] || fail "precondition: dir must not exist yet"
  "$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" >/dev/null 2>&1
  [ -d "$OMAMAC_SCREENSHOT_DIR" ] || fail "the screenshot directory must be created"
}

test_screenshot_goes_to_the_clipboard_as_well_as_to_a_file() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" >/dev/null
  assert_contains "$(cat "$TMPDIR_TEST/osascript.args")" "clipboard"
}

test_save_keeps_the_file_off_the_clipboard() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" --save >/dev/null
  [ ! -f "$TMPDIR_TEST/osascript.args" ] || fail "--save must not touch the clipboard"
  [ -n "$(find "$OMAMAC_SCREENSHOT_DIR" -name 'screenshot-*.png')" ] || fail "--save must still write the file"
}

test_copy_leaves_no_file_behind() {
  setup_capture
  "$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" --copy >/dev/null
  assert_contains "$(cat "$TMPDIR_TEST/osascript.args")" "clipboard"
  [ -z "$(find "$OMAMAC_SCREENSHOT_DIR" -name 'screenshot-*.png')" ] \
    || fail "--copy must not leave a file in the screenshot directory"
}

# The host shows an applied command's stdout as an alert. A screenshot that
# says nothing looks like one that did not happen.
test_screenshot_reports_itself_on_stdout() {
  setup_capture
  local out; out=$("$OMAMAC_BIN" capture --screenshot --region "0,0 10x10")
  assert_contains "$out" "Screenshot"
}

# Escape during the pick. screencapture exits 0 and writes nothing, so this is
# the case that the exit status cannot detect — the file has to be the test.
test_a_cancelled_capture_is_silent_and_successful() {
  setup_capture
  export CAP_CANCEL=1
  # stdout only. stderr carries log_* and is not what the host shows; asserting
  # against both makes this fail on the directory-created notice instead.
  local out; out=$("$OMAMAC_BIN" capture --screenshot 2>/dev/null)
  assert_eq 0 "$?" "cancelling a screenshot is not an error"
  assert_eq "" "$out" "a cancelled screenshot must say nothing"
  [ -z "$(find "$OMAMAC_SCREENSHOT_DIR" -name 'screenshot-*.png' 2>/dev/null)" ] \
    || fail "a cancelled screenshot must leave no file"
}

# A zero-byte file is what a failed capture leaves. Treating it as a success
# puts an empty PNG on the clipboard and reports it saved.
test_an_empty_capture_is_treated_as_a_cancel() {
  setup_capture
  cat > "$TMPDIR_TEST/screencapture" <<'STUB'
#!/usr/bin/env bash
: > "${@: -1}"
STUB
  chmod +x "$TMPDIR_TEST/screencapture"
  local out; out=$("$OMAMAC_BIN" capture --screenshot --region "0,0 10x10" 2>/dev/null)
  assert_eq "" "$out" "an empty capture must not be reported as saved"
  [ ! -f "$TMPDIR_TEST/osascript.args" ] || fail "an empty capture must not reach the clipboard"
}

# --------------------------------------------------------------- recording --

test_recording_writes_a_mov_not_an_mp4() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  # After stopping, not before: screencapture creates the file only when it
  # finalises, so mid-recording there is nothing on disk to name.
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
  local f; f=$(find "$OMAMAC_SCREENRECORD_DIR" -name 'screenrecording-*' | head -1)
  [ -n "$f" ] || fail "no recording written"
  # screencapture writes a QuickTime container whatever the extension, so .mp4
  # would misname the file. Upstream's own name is screenrecording-<stamp>.
  basename "$f" | grep -qE '^screenrecording-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.mov$' \
    || fail "recording must be screenrecording-<date>_<time>.mov, got $(basename "$f")"
}

# Nothing on disk until it stops. If this ever starts failing, the readiness
# check in start_recording can go back to waiting for the file.
test_no_file_exists_while_a_recording_is_running() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  local n; n=$(find "$OMAMAC_SCREENRECORD_DIR" -name 'screenrecording-*' | wc -l | tr -d ' ')
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
  assert_eq 0 "$n" "screencapture writes nothing until it finalises"
}

test_status_is_quiet_and_nonzero_when_not_recording() {
  setup_capture
  local out; out=$("$OMAMAC_BIN" capture --status 2>&1)
  assert_eq 1 "$?" "--status must exit non-zero when nothing is recording"
  assert_eq "" "$out" "--status must print nothing when nothing is recording"
}

test_status_reports_an_active_recording() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  assert_contains "$("$OMAMAC_BIN" capture --status)" "recording"
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
}

# SIGINT, not SIGTERM: screencapture only writes the moov atom — the index that
# makes the file playable — on interrupt. The stub appends "moov" on INT, so a
# recording stopped any other way is detectably unplayable.
test_stopping_finalises_the_file() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  "$OMAMAC_BIN" capture --stop >/dev/null
  # Located after the stop: there is no file before it.
  local f; f=$(find "$OMAMAC_SCREENRECORD_DIR" -name 'screenrecording-*.mov' | head -1)
  [ -n "$f" ] || fail "stopping must leave a file behind"
  assert_contains "$(cat "$f")" "moov"
}

test_stopping_clears_the_marker() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  "$OMAMAC_BIN" capture --stop >/dev/null
  [ ! -f "$OMAMAC_STATE/recording" ] || fail "the recording marker must be cleared"
  "$OMAMAC_BIN" capture --status >/dev/null 2>&1 && fail "--status must be false after stopping"
}

test_stopping_when_not_recording_is_an_error() {
  setup_capture
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1 && fail "--stop must exit non-zero when nothing is recording"
}

# Upstream's screenrecording script is a toggle. Without that, picking Record
# twice leaves two recorders fighting over the display and one orphaned.
test_record_toggles_rather_than_starting_a_second_recorder() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  local out; out=$("$OMAMAC_BIN" capture --record)
  assert_contains "$out" "saved"
  # Exactly one file: the second --record stopped the first rather than
  # starting a recorder that would leave a second one behind.
  local after; after=$(find "$OMAMAC_SCREENRECORD_DIR" -name '*.mov' | wc -l | tr -d ' ')
  assert_eq 1 "$after" "the second --record must stop, not start another recording"
  "$OMAMAC_BIN" capture --status >/dev/null 2>&1 && fail "the toggle must leave nothing recording"
}

test_audio_is_off_unless_asked_for() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  local args; args=$(cat "$CAP_LOG")
  case " $args " in *" -g "*) fail "audio must be off by default" ;; esac
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
}

test_audio_uses_the_default_input() {
  setup_capture
  "$OMAMAC_BIN" capture --record --audio >/dev/null
  assert_contains "$(cat "$CAP_LOG")" "-g"
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
}

test_a_region_recording_passes_the_rect_through() {
  setup_capture
  "$OMAMAC_BIN" capture --record --region "100,200 640x480" >/dev/null
  assert_contains "$(cat "$CAP_LOG")" "-R 100,200,640,480"
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
}

# A recorder that dies immediately (rejected region, no Screen Recording
# permission) must not leave a marker behind claiming a recording is running —
# the menu would then offer to stop something that is not there.
test_a_recorder_that_dies_immediately_records_no_marker() {
  setup_capture
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMPDIR_TEST/screencapture"
  chmod +x "$TMPDIR_TEST/screencapture"
  "$OMAMAC_BIN" capture --record >/dev/null 2>&1 && fail "a failed start must exit non-zero"
  [ ! -f "$OMAMAC_STATE/recording" ] || fail "a failed start must leave no marker"
}

# The marker holds a pid. Pids are recycled, and the user's own Cmd-Shift-5
# recording is a different process — so a stale marker whose pid now belongs to
# something else must read as "not recording" rather than get signalled.
test_a_stale_marker_whose_pid_is_now_something_else_is_not_a_recording() {
  setup_capture
  mkdir -p "$OMAMAC_STATE"
  printf '%s\n%s\n' "$$" "$OMAMAC_SCREENRECORD_DIR/screenrecording-gone.mov" \
    > "$OMAMAC_STATE/recording"
  "$OMAMAC_BIN" capture --status >/dev/null 2>&1 \
    && fail "a marker pointing at an unrelated live process must not read as recording"
}

# The recorder is believed started once it has survived a grace period, NOT
# once its output file appears — screencapture creates that only when it stops,
# so waiting for it stalls every start until the timeout. Measured in Python
# because a whole-second clock cannot tell 0.2s from 4s reliably.
test_starting_a_recording_returns_promptly() {
  setup_capture
  local elapsed
  elapsed=$(python3 -c "
import subprocess, sys, time
t0 = time.time()
subprocess.run(['$OMAMAC_BIN', 'capture', '--record'], capture_output=True)
print(f'{time.time() - t0:.2f}')
")
  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
  python3 -c "
import sys
e = float('$elapsed')
sys.exit(0 if e < 1.5 else 1)" \
    || fail "starting a recording took ${elapsed}s — it must not wait on a file that only appears at the end"
}

# `kill -0` succeeds on a zombie — a child that has exited but not yet been
# waited for — so it cannot answer "is the recorder running". Whether bash has
# reaped a dead child by the time the check runs is a matter of scheduling, so
# the timing-based test above catches this only by luck. This asks the question
# directly: ps reports state Z, and a Z process is not a recording.
test_a_zombie_process_does_not_count_as_a_recording() {
  setup_capture
  "$OMAMAC_BIN" capture --record >/dev/null
  local pid; pid=$(sed -n 1p "$OMAMAC_STATE/recording")

  # ps that reports the recorder as a zombie, and otherwise tells the truth
  # about its command line — so only the state distinguishes the two cases.
  cat > "$TMPDIR_TEST/ps" <<PSSTUB
#!/usr/bin/env bash
case "\$*" in
  *state*) printf 'Z\n' ;;
  *command*) printf '%s\n' "screencapture -v \$(sed -n 2p "$OMAMAC_STATE/recording")" ;;
esac
PSSTUB
  chmod +x "$TMPDIR_TEST/ps"

  OMAMAC_PS="$TMPDIR_TEST/ps" "$OMAMAC_BIN" capture --status >/dev/null 2>&1 \
    && fail "a zombie must not read as a running recording"

  # Control: the same stub reporting a live state DOES count, so the test above
  # is detecting the state and not something incidental about the stub.
  cat > "$TMPDIR_TEST/ps" <<PSSTUB
#!/usr/bin/env bash
case "\$*" in
  *state*) printf 'S\n' ;;
  *command*) printf '%s\n' "screencapture -v \$(sed -n 2p "$OMAMAC_STATE/recording")" ;;
esac
PSSTUB
  chmod +x "$TMPDIR_TEST/ps"
  OMAMAC_PS="$TMPDIR_TEST/ps" "$OMAMAC_BIN" capture --status >/dev/null 2>&1 \
    || fail "control: a running state must read as a recording"

  "$OMAMAC_BIN" capture --stop >/dev/null 2>&1
}

run_tests

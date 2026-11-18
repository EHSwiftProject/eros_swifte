#!/usr/bin/env bash
# Local CI: privacy guards, package and capture tool tests on Mac, project generation, then three simulators: simulator
# package tests, app unit and UI tests on the iPhone Duo, the UI tests on an iPhone, the app unit and UI tests on an
# iPad. One simulator runs at a time, and each device starts once the host load is low enough (see wait_for_low_load).
# A step on Mac that fails stops the script. A device whose tests fail, or that cannot be readied, does not stop the
# others: every test run's result is printed as it ends ("==> Result: ...") and kept, and a summary follows the last
# device, with how often XCTest waited 60 s for the app's animations, by test.
# A signal (SIGTERM, as from an outer timeout; SIGINT; SIGHUP) ends the run under way and the script at once, with the
# signal's status (128 + its number): the summary of the runs so far is printed all the same, the simulator in use is
# shut down, and the last line is TESTS INTERRUPTED: and what ended them. So it is when the script itself fails during
# the device runs. A signal once every run is over, during the summary, is let go.
# Exit codes: 0 all passed; 2 EROS_ONLY_TESTING named nothing a device runs; else the first failure's: 3 simulator not
# ready (or not unique, or not created), other non-zero = a step failed. The last line is ALL TESTS PASSED, TESTS
# FAILED: and the runs that failed, by device, NO TESTS RAN (...), or TESTS INTERRUPTED: ...
#
# EROS_ONLY_TESTING (local checks of this script's own flow only): xcodebuild test identifiers, separated by spaces
# (ErosUITests/TabContainerTests/testVisibleTabsAreSelectable, ErosTests/AppSettingsTests). The steps on Mac after the
# guards and the simulator package tests are skipped; each device runs only the identifiers of its targets, and a
# device whose targets have none is skipped. One in neither target is warned about; when nothing ran at all, the last
# line is NO TESTS RAN and the status 2. Never for a gate run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# iPhone Duo (eros): every simulator test runs on it.
UDID="${EROS_SIM_UDID:-DB11837C-0611-469E-99BE-B113D89CA1E0}"
# The UI tests also run on these two, found by name and created when missing (unless a UDID is given). Latest standard
# iPhone and iPad Pro 13-inch on the iOS 27.2 runtime, checked with `xcrun simctl list devicetypes` on 2026-11-08.
IPHONE_NAME="iPhone (eros)"
IPAD_NAME="iPad (eros)"
IPHONE_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
IPAD_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
SIM_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-2"
cd "$repo_root"

# Prints the UDID of the one available simulator named <name>, creating it (<device type>, SIM_RUNTIME) when there is
# none. Fails (status 3) when the name is not unique or the list or the creation fails; callers add `|| exit 3`.
simulator_udid() {
    local name="$1" device_type="$2" devices matches count
    devices="$(timeout 60 xcrun simctl list devices available)" || return 3
    # Device lines are "    <name> (<UDID>) (<state>)": the name is matched literally, right after the four spaces.
    matches="$(printf '%s\n' "$devices" | grep -F -- "    $name (" \
        | awk -v prefix="    $name (" 'index($0, prefix) == 1' || true)"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    case "$count" in
        0)
            echo "creating simulator: $name ($device_type, $SIM_RUNTIME)" >&2
            timeout 60 xcrun simctl create "$name" "$device_type" "$SIM_RUNTIME" || return 3
            ;;
        1)
            printf '%s\n' "$matches" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1
            ;;
        *)
            echo "simulator name is not unique: $name" >&2
            exit 3
            ;;
    esac
}

# Boots <udid> and waits for it; on failure shuts it down and tries once more, then exits 3.
ensure_booted() {
    local udid="$1"
    echo "==> Simulator ready: $udid"
    if ! timeout 60 xcrun simctl bootstatus "$udid" -b; then
        timeout 60 xcrun simctl shutdown "$udid" || true
        if ! timeout 60 xcrun simctl bootstatus "$udid" -b; then
            echo "simulator not ready: $udid" >&2
            exit 3
        fi
    fi
}

# Shuts down every booted simulator except <udid> (shut down only, never erased): one simulator at a time, so that
# no other one's system services compete with the device under test.
shutdown_other_simulators() {
    local keep="$1" booted other
    if ! booted="$(timeout 60 xcrun simctl list devices booted)"; then
        echo "could not list the booted simulators" >&2
        exit 3
    fi
    for other in $(printf '%s\n' "$booted" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' || true); do
        if [ "$other" != "$keep" ]; then
            echo "==> Shutting down simulator $other"
            timeout 60 xcrun simctl shutdown "$other" || true
        fi
    done
}

# WebKit's helper processes (web content, networking, GPU) take seconds to launch, and its cookie store calls stall,
# when the host is heavily loaded: past the app's 5 s user agent read and the UI tests' waits (task C9, 2026-11-09: on
# 10 logical CPUs, at a 1-minute load above 30 the web login tests failed; at about 8 they passed every time). So a
# device starts once the 1-minute load average is below 2 x the logical CPUs, checked every 30 s; after 15 min it
# starts anyway, with a warning. The swap in use is told too, with a warning above SWAP_WARNING_MB: with the swap full
# WebKit's store calls slowed down as well (M2 entry, iPad runs of 2026-11-16), so a timing failure then is suspect.
LOAD_LIMIT=$((2 * $(sysctl -n hw.logicalcpu)))
SWAP_WARNING_MB=8192
wait_for_low_load() {
    local load waited=0
    while :; do
        load="$(sysctl -n vm.loadavg | awk '{print $2}')"
        if awk -v load="$load" -v limit="$LOAD_LIMIT" 'BEGIN { exit !(load < limit) }'; then
            echo "==> Host load $load (limit $LOAD_LIMIT)"
            warn_on_swap
            return 0
        fi
        if [ "$waited" -ge 900 ]; then
            echo "warning: host load still $load after 15 min (limit $LOAD_LIMIT); starting anyway" >&2
            warn_on_swap
            return 0
        fi
        echo "==> Host load $load (limit $LOAD_LIMIT): checking again in 30 s"
        sleep 30
        waited=$((waited + 30))
    done
}

# Prints the swap in use (`vm.swapusage`, "used = 6597.06M"), with a warning above SWAP_WARNING_MB.
warn_on_swap() {
    local used
    used="$(sysctl -n vm.swapusage | awk '{
        for (i = 1; i < NF; i++) if ($i == "used") {
            value = $(i + 2); unit = substr(value, length(value)); value = substr(value, 1, length(value) - 1) + 0
            if (unit == "G") value *= 1024; print int(value); exit
        }
    }')"
    if [ -z "$used" ]; then
        echo "==> Swap in use: unknown"
    elif [ "$used" -gt "$SWAP_WARNING_MB" ]; then
        echo "warning: swap in use ${used} MB (above ${SWAP_WARNING_MB} MB): WebKit's timing tests may fail" >&2
    else
        echo "==> Swap in use ${used} MB"
    fi
}

# Makes <udid> the only booted simulator and waits for a low host load, its own boot included: a simulator that
# was just booted starts its system services for minutes afterwards (a 1-minute load above 200 on 10 logical CPUs,
# 2026-11-09), and the 1-minute average lags, so a fresh boot waits 60 s before the first look.
prepare_device() {
    local was_booted=0 booted
    shutdown_other_simulators "$1"
    # Read whole before it is searched: `grep -q` quits at the first match, and under pipefail the simctl it read from
    # would fail on the closed pipe, as if the device were not booted.
    booted="$(timeout 60 xcrun simctl list devices booted || true)"
    case "$booted" in
        *"($1)"*) was_booted=1 ;;
    esac
    ensure_booted "$1"
    if [ "$was_booted" -eq 0 ]; then
        echo "==> Simulator just booted: waiting 60 s before checking the host load"
        sleep 60
    fi
    wait_for_low_load
}

# A class loaded twice (e.g. a package product linked into both the app and ErosTests) breaks casts at random.
# Duplicates where both copies are in the simulator runtime's own system (/RuntimeRoot/ twice) are Apple's and
# show up on every UI test run, so they are let through. Returns 1 when there are others.
check_duplicate_classes() {
    local log="$1" duplicate_classes
    duplicate_classes="$(grep 'implemented in both' "$log" | awk -F'/RuntimeRoot/' 'NF < 3' || true)"
    if [ -n "$duplicate_classes" ]; then
        echo "duplicate classes in the app tests ('implemented in both'): link each package product only once, see project.yml" >&2
        return 1
    fi
}

# What the device runs report, kept for the summary: one line per run ("<device>: <run> passed" or "... FAILED (exit
# <n>)"), the failed runs for the last line, and the first failure's status (0 while none failed). Strings, not
# arrays: an empty array is an unbound variable to set -u in the bash macOS ships.
results=""
failures=""
first_failure=0
# The script's status after a whole run, set by print_summary.
summary_status=0
# For a run that is ended early: the step under way ("the steps on Mac", "<device> ErosUITests"), the device and run
# under way (none between runs), the simulator in use (shut down on exit), the background job waited for and the tee
# that copies a device run's output (both ended on exit).
step="the privacy guards"
current_device=""
current_run=""
current_udid=""
running_pid=""
tee_pid=""
# The signal that ended the script, if one did; whether the device runs began; whether the summary is out.
interrupted=""
devices_started=0
summary_printed=0

# Records the <status> of <run> on <device>, and prints it at once: a run cut short by an outer timeout keeps every
# result so far in its log.
record() {
    local device="$1" run="$2" status="$3" line
    if [ "$status" -eq 0 ]; then
        line="${device}: ${run} passed"
    else
        line="${device}: ${run} FAILED (exit ${status})"
        failures="${failures:+$failures; }${device} ${run} (exit ${status})"
        if [ "$first_failure" -eq 0 ]; then
            first_failure="$status"
        fi
    fi
    results="${results}${line}"$'\n'
    echo "==> Result: $line"
}

# Waits for the background job <pid>, kept in running_pid meanwhile for the exit trap to end; returns its status. The
# long steps run as background jobs, as bash runs a trap only once the command in the foreground ends but at once while
# `wait` waits: a signal ends the script without waiting for, say, the rest of a UI test run.
wait_for_job() {
    local status=0
    running_pid="$1"
    wait "$1" || status=$?
    running_pid=""
    return "$status"
}

# Runs <command...> as a background job whose output (both streams) is shown and kept in <log>, and waits for it
# (`wait_for_job`); returns its status. Through a FIFO and tee rather than a pipe, so that both processes are known.
run_logged() {
    local log="$1" fifo="$log_dir/output.fifo" status=0
    shift
    rm -f "$fifo"
    mkfifo "$fifo"
    tee "$log" < "$fifo" &
    tee_pid=$!
    "$@" > "$fifo" 2>&1 &
    wait_for_job $! || status=$?
    wait "$tee_pid" || true
    tee_pid=""
    rm -f "$fifo"
    return "$status"
}

# Ends the job <pid>: sends it <signal> (none: lets it end by itself), waits up to <seconds> for it, then kills it.
# shellcheck disable=SC2329 # called by on_exit, the exit trap
end_job() {
    local pid="$1" seconds="$2" signal="${3:-}" waited=0
    if [ -n "$signal" ]; then
        kill "-$signal" "$pid" 2>/dev/null || true
    fi
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$seconds" ]; do
        sleep 1 || true
        waited=$((waited + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Test timeouts (`-test-timeouts-enabled YES`): a test that runs past its allowance fails, and the run goes on with the
# next one (the test process is ended and started again), instead of a hang holding the whole run until an outer
# timeout ends it. The allowance is Swift Testing's default time limit too (measured on iOS 27.2: a test without one of
# its own failed with "Time limit was exceeded" at the allowance). The allowances, in seconds (rounded up to whole
# minutes), by target, with room over the slowest of the M2 full runs (E4b ALL4, ALL5):
# - ErosTests 300: the slowest test took 15 s (ForumProfileLoaderTests.failedLoadsWriteNothing on the Duo). The
#   suites that wait for something a test lets go have limits of their own (`.timeLimit`): 1 min, and 5 min for the
#   WebKit suites (an account flow test once took 143 s under a heavy load).
# - ErosUITests 600: the slowest without XCTest's 60 s waits for the app's animations took 140 s
#   (ScreenTourTests.testTourT1toT3). A test caught in those waits, one after each action, took 413–652 s and once
#   about 40 min (the iPad's SearchFilterTests, M2 review F2); it now fails at 10 min, and the summary counts the
#   waits.
UNIT_TEST_ALLOWANCE=300
UI_TEST_ALLOWANCE=600

# Prints the -only-testing arguments of <target> from EROS_ONLY_TESTING, one per line: nothing when it is not set,
# "none" when it is set and names nothing of <target> (the run is skipped).
only_testing_arguments() {
    local target="$1" identifier found=0
    [ -n "${EROS_ONLY_TESTING:-}" ] || return 0
    for identifier in $EROS_ONLY_TESTING; do
        case "$identifier" in
            "$target" | "$target"/*)
                printf -- '-only-testing:%s\n' "$identifier"
                found=1
                ;;
        esac
    done
    [ "$found" -eq 1 ] || echo none
}

# Runs the tests of <target> (ErosTests or ErosUITests) on <udid>, the output kept in <log> (`run_logged`); returns
# xcodebuild's status, else 1 for a class loaded twice. Ad-hoc signed (identity "-") so ErosTests can use the Keychain
# inside the app; user decision, 2026-11-06.
run_app_tests() {
    local udid="$1" target="$2" log="$3" allowance status=0 only
    allowance="$UNIT_TEST_ALLOWANCE"
    [ "$target" = ErosUITests ] && allowance="$UI_TEST_ALLOWANCE"
    only="$(only_testing_arguments "$target")"
    # shellcheck disable=SC2046 # one -only-testing argument per line, none of them with a space
    run_logged "$log" xcodebuild test -project Eros.xcodeproj -scheme Eros -destination "id=$udid" \
        $(if [ -n "$only" ]; then printf '%s\n' "$only"; else echo "-only-testing:$target"; fi) \
        -test-timeouts-enabled YES -default-test-execution-time-allowance "$allowance" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- || status=$?
    [ "$status" -eq 0 ] || return "$status"
    check_duplicate_classes "$log" || return 1
}

# EHStoreTests run on the Duo as well: the iOS runtime's SQLite decides whether FTS5 is available. A background job
# (`wait_for_job`) that becomes xcodebuild once in the package's directory.
run_simulator_package_tests() {
    local udid="$1"
    (
        cd "$repo_root/Packages/ErosKit" || exit 1
        exec xcodebuild test -scheme ErosKit-Package -destination "id=$udid" \
            -only-testing:EHStoreTests -only-testing:EHDownloadTests -only-testing:EHReaderTests \
            CODE_SIGNING_ALLOWED=NO
    ) &
    wait_for_job $!
}

# Runs <runs> (package: the simulator package tests; ErosTests; ErosUITests) on the simulator named <name> (<udid>
# when given, else found or created) as the only booted one, records each run's result and goes on after a failure,
# then shuts the simulator down (a failed shutdown is ignored). A simulator that cannot be found, created or readied
# is recorded as a failure with status 3 and its runs are skipped; so are runs EROS_ONLY_TESTING leaves nothing to.
test_device() {
    local name="$1" device_type="$2" udid="$3" slug="$4" run status todo=""
    shift 4
    for run in "$@"; do
        if [ "$run" = package ] && [ -n "${EROS_ONLY_TESTING:-}" ]; then continue; fi
        if [ "$run" != package ] && [ "$(only_testing_arguments "$run")" = none ]; then continue; fi
        todo="$todo $run"
    done
    if [ -z "$todo" ]; then
        echo "==> $name: nothing to run (EROS_ONLY_TESTING)"
        return 0
    fi
    echo "==> Tests on $name:$todo"
    current_device="$name"
    current_run="simulator"
    step="$name simulator"
    if [ -z "$udid" ]; then
        if ! udid="$(simulator_udid "$name" "$device_type")"; then
            record "$name" "simulator" 3
            current_run=""
            return 0
        fi
    fi
    current_udid="$udid"
    # A background job, so a subshell: its steps exit 3 when the simulator is not ready, which ends this device only.
    status=0
    prepare_device "$udid" &
    wait_for_job $! || status=$?
    if [ "$status" -ne 0 ]; then
        record "$name" "simulator" "$status"
        current_run=""
        timeout 60 xcrun simctl shutdown "$udid" || true
        current_udid=""
        return 0
    fi
    for run in $todo; do
        status=0
        case "$run" in
            package)
                current_run="simulator package tests"
                step="$name $current_run"
                echo "==> Package tests on $name (xcodebuild)"
                run_simulator_package_tests "$udid" || status=$?
                record "$name" "simulator package tests" "$status"
                ;;
            *)
                current_run="$run"
                step="$name $run"
                echo "==> $run on $name (xcodebuild)"
                run_app_tests "$udid" "$run" "$log_dir/$slug-$run.log" || status=$?
                record "$name" "$run" "$status"
                ;;
        esac
    done
    current_run=""
    step="$name shutdown"
    timeout 60 xcrun simctl shutdown "$udid" || true
    current_udid=""
}

# Prints how often each test waited 60 s for the app's animations ("App animations complete notification not
# received": XCTest gives up on its idle wait and goes on), from the UI test logs, most first, as
# "<count>  <device log>  <class>.<test>"; "none" without any. A test case's lines follow its "Test Case ... started."
# line, test iterations add up.
count_animation_waits() {
    local log counts=""
    for log in "$log_dir"/*-ErosUITests.log; do
        [ -f "$log" ] || continue
        counts="${counts}$(awk -v device="$(basename "$log" -ErosUITests.log)" '
            /^Test Case .* started/ {
                test = $0; sub(/^Test Case .-\[[^.]*\./, "", test); sub(/\].*$/, "", test); sub(/ /, ".", test)
            }
            /App animations complete notification not received/ { waits[test]++ }
            END { for (t in waits) printf "%d  %s  %s\n", waits[t], device, t }
        ' "$log")"$'\n'
    done
    counts="$(printf '%s' "$counts" | grep . | sort -rn || true)"
    if [ -n "$counts" ]; then printf '%s\n' "$counts"; else echo "none"; fi
}

# Prints the summary: every run's result, XCTest's 60 s waits by test, and the last line. Given <interruption> (what
# ended the runs early: "SIGTERM during iPad (eros) ErosUITests"), the run it cut short is listed as INTERRUPTED and the
# last line is TESTS INTERRUPTED: <interruption>, with the runs that failed before it; never ALL TESTS PASSED. Else NO
# TESTS RAN when EROS_ONLY_TESTING left every device nothing, TESTS FAILED, or ALL TESTS PASSED. Sets summary_status:
# 0, 2 (nothing ran) or the first failure's.
print_summary() {
    local interruption="${1:-}"
    summary_printed=1
    summary_status="$first_failure"
    echo "==> Summary"
    printf '%s' "$results"
    if [ -n "$interruption" ] && [ -n "$current_run" ]; then
        echo "${current_device}: ${current_run} INTERRUPTED"
    fi
    echo "==> XCTest's 60 s waits for the app's animations, by test"
    count_animation_waits
    if [ -n "$interruption" ]; then
        echo "TESTS INTERRUPTED: ${interruption}${failures:+; failed before: $failures}"
    elif [ -z "$results" ] && [ -n "${EROS_ONLY_TESTING:-}" ]; then
        echo "NO TESTS RAN (EROS_ONLY_TESTING matched no target)"
        summary_status=2
    elif [ "$first_failure" -ne 0 ]; then
        echo "TESTS FAILED: $failures"
    else
        echo "ALL TESTS PASSED"
    fi
}

# On exit (a whole run, a failed step on Mac, a signal, or an error of the script's own): ends a job still going, then
# prints the summary unless it is out (after a signal, or once the device runs began), shuts the simulator in use down
# (quietly: the summary's line stays the last; once more after 5 s when that fails) and removes the logs. The job is
# the run cut short; its output comes before the summary.
# A simulator's preparation is a subshell whose simctl runs in the foreground under a `timeout` of its own process
# group: ending the subshell would leave that running, to write after the last line and to boot the simulator past its
# shutdown (M2 re-review F4 m-1). So the subshell's direct children, found by parent PID alone (this script's own),
# are ended once it has gone, waiting up to 5 s for them.
# shellcheck disable=SC2329 # the exit trap
on_exit() {
    local status=$?
    local kids="" kid waited=0
    # All of this is best effort, and `set -e` still holds in a trap: a command that fails here, or that a second
    # Ctrl-C ends (it reaches the whole process group, a `sleep` here included), must not end the script before the
    # summary's last line (M2 final re-review m-1).
    set +e
    # Another signal (an outer timeout's again) must not cut the summary short. Caught, not ignored: what is started
    # from here would inherit an ignored signal, and `timeout` could not end it.
    trap ':' TERM INT HUP
    if [ -n "$running_pid" ]; then
        if [ "$current_run" = simulator ]; then kids="$(pgrep -P "$running_pid" || true)"; fi
        end_job "$running_pid" 30 TERM
        for kid in $kids; do kill -TERM "$kid" 2>/dev/null || true; done
        for kid in $kids; do
            while kill -0 "$kid" 2>/dev/null && [ "$waited" -lt 5 ]; do
                sleep 1 || true
                waited=$((waited + 1))
            done
        done
    fi
    if [ -n "$tee_pid" ]; then end_job "$tee_pid" 5; fi
    if [ "$summary_printed" -eq 0 ] && { [ -n "$interrupted" ] || [ "$devices_started" -eq 1 ]; }; then
        print_summary "${interrupted:-exit $status} during $step"
    fi
    if [ -n "$current_udid" ]; then
        timeout 60 xcrun simctl shutdown "$current_udid" > /dev/null 2>&1 \
            || { sleep 5 || true; timeout 60 xcrun simctl shutdown "$current_udid" > /dev/null 2>&1 || true; }
    fi
    rm -rf "$log_dir"
}

# The output of every app test run is kept to look for duplicate classes and to count the 60 s waits; all of it is
# removed on exit.
log_dir="$(mktemp -d -t eros-app-tests)"
trap on_exit EXIT
# Each first catches all three, as on_exit does, before anything else: a second signal (an outer timeout's again, a
# second Ctrl-C) arriving before on_exit has would end the script inside it, without the summary (M2 re-review F4 m-3).
trap 'trap ":" TERM INT HUP; interrupted=SIGTERM; exit 143' TERM
trap 'trap ":" TERM INT HUP; interrupted=SIGINT; exit 130' INT
trap 'trap ":" TERM INT HUP; interrupted=SIGHUP; exit 129' HUP

echo "==> Privacy guards"
# Local-only fixtures and capture secrets must stay git-ignored, and nothing but .gitkeep may be tracked under local/.
# Output names paths only.
for ignored in \
    Packages/ErosKit/Tests/Fixtures/local/x \
    .fixture-secrets.local \
    .fixture-secrets.local.x.tmp \
    Tools/FixtureCapture/capture.env; do
    if ! git check-ignore -q --no-index -- "$ignored"; then
        echo "privacy guard failed: not git-ignored: $ignored" >&2
        exit 1
    fi
done
tracked_local="$(git ls-files Packages/ErosKit/Tests/Fixtures/local)"
if [ "$tracked_local" != "Packages/ErosKit/Tests/Fixtures/local/.gitkeep" ]; then
    echo "privacy guard failed: tracked files under Packages/ErosKit/Tests/Fixtures/local other than .gitkeep:" >&2
    printf '%s\n' "$tracked_local" >&2
    exit 1
fi
# Secrets must never be tracked (even if force-added), and must not be left untracked-but-unignored.
# Output names paths only.
tracked_secrets="$(git ls-files -- '.fixture-secrets.local*' Tools/FixtureCapture/capture.env)"
if [ -n "$tracked_secrets" ]; then
    echo "privacy guard failed: tracked secret files: $(printf '%s' "$tracked_secrets" | tr '\n' ' ')" >&2
    exit 1
fi
stray_local="$(git ls-files --others --exclude-standard -- Packages/ErosKit/Tests/Fixtures/local '.fixture-secrets.local*' Tools/FixtureCapture/capture.env)"
if [ -n "$stray_local" ]; then
    echo "privacy guard failed: untracked and not ignored local files: $(printf '%s' "$stray_local" | tr '\n' ' ')" >&2
    exit 1
fi
if [ "${EROS_TEST_GUARDS_ONLY:-}" = "1" ]; then
    echo "GUARDS PASSED"
    exit 0
fi

if [ -n "${EROS_ONLY_TESTING:-}" ]; then
    echo "==> EROS_ONLY_TESTING: $EROS_ONLY_TESTING (the steps on Mac and the simulator package tests are skipped)"
    for identifier in $EROS_ONLY_TESTING; do
        case "$identifier" in
            ErosTests | ErosTests/* | ErosUITests | ErosUITests/*) ;;
            *)
                echo "warning: EROS_ONLY_TESTING: $identifier is in neither ErosTests nor ErosUITests:" \
                    "nothing runs it" >&2
                ;;
        esac
    done
else
    # As background jobs (`wait_for_job`), so a signal is handled at once; one that fails stops the script (set -e).
    step="the steps on Mac"
    echo "==> Package tests on Mac (swift test)"
    # --filter is a regex; alternatives that match nothing (e.g. EHFixturesTests before Task 8) are harmless.
    swift test --package-path Packages/ErosKit \
        --filter 'EHModelsTests|EHParsingTests|EHNetworkTests|EHFixturesTests|EHStoreTests' &
    wait_for_job $!

    echo "==> Capture tool tests on Mac (swift test)"
    swift test --package-path Tools/FixtureCapture &
    wait_for_job $!

    echo "==> WebDAV spike tests (offline)"
    # Clear all three variables so the integration tests never reach a local WebDAV server.
    env -u WEBDAV_SPIKE_URL -u WEBDAV_SPIKE_DIGEST_URL -u WEBDAV_SPIKE_LEGACY_BASE \
        swift test --package-path Spikes/WebDAV &
    wait_for_job $!

    echo "==> DoH spike build"
    # Build only (including tests); nothing here touches the network.
    swift build --package-path Spikes/DoHHosts --build-tests &
    wait_for_job $!
fi

step="the project's generation"
echo "==> Generate Xcode project"
scripts/generate.sh

# The unit tests on the Duo and the iPad, not the iPhone: the iPad is another idiom, where WebKit browses as on a
# desktop unless told otherwise (M2 review A-I1: the user agent its pages sent differed from the probe's there, which
# only the iPad's unit tests showed); the iPhone is the Duo's idiom, where they passed alike (479 of 479). The UI tests
# on all three.
devices_started=1
test_device "iPhone Duo (eros)" "" "$UDID" duo package ErosTests ErosUITests
test_device "$IPHONE_NAME" "$IPHONE_DEVICE_TYPE" "${EROS_IPHONE_UDID:-}" iphone ErosUITests
test_device "$IPAD_NAME" "$IPAD_DEVICE_TYPE" "${EROS_IPAD_UDID:-}" ipad ErosTests ErosUITests

step="the summary"
# Every run is over: a signal now could only cut the summary short, without its last line (M2 re-review F4 m-3). Nor
# may a command of the summary's that a signal to the process group ends (M2 final re-review m-1).
trap ':' TERM INT HUP
set +e
print_summary
exit "$summary_status"

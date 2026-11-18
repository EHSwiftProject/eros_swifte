#!/bin/bash
# Check that a Release Eros.app carries no test hooks. Usage: scripts/check-release-app.sh <path to Eros.app>
# Used by scripts/build-ipa.sh and scripts/upload-asc.sh. Exit codes: 0 clean, 64 bad usage, 1 the app carries test
# hooks, has no binary, or could not be searched (never a pass).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/check-release-app.sh <path to Eros.app>" >&2
  exit 64
fi
app="$1"

# Test hooks are DEBUG only: no replay fixtures (scripts/copy-replay-fixtures.sh copies them into Debug builds) and no
# test switch anywhere in the app (-EROS_UI_TESTING*, -EROS_UI_TEST_IMAGE, -EROS_FIXTURE_*, EROS_FIXTURE_ROUTES). The
# app names every switch with a StaticString (App/Debug/TestSwitches.swift), whose bytes are stored whole; a short
# String literal would not be. The whole bundle is searched, so a dylib or framework added later is covered.
if [ ! -f "$app/Eros" ]; then
  echo "release build has no app binary: $app/Eros" >&2
  exit 1
fi
if [ -e "$app/FixtureReplay" ]; then
  echo "release build carries test hooks" >&2
  exit 1
fi
# grep: 0 found, 1 not found (the only pass), anything else could not search (a failure, never a pass).
hooks_status=0
grep -r -a -q -e EROS_UI_TEST -e EROS_FIXTURE "$app" || hooks_status=$?
case "$hooks_status" in
  0)
    echo "release build carries test hooks" >&2
    exit 1
    ;;
  1) ;;
  *)
    echo "could not search the release build for test hooks (grep exit $hooks_status)" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# Build phase of the Eros target (project.yml): copies the checked-in fixtures into a Debug app bundle, where
# FixtureReplay answers UI test requests from them (-EROS_FIXTURE_REPLAY 1). Only eh, ex, constructed and
# manifest.json, by name: never local/ (private captures). Any other configuration removes the directory and copies
# nothing, so a Release build carries no fixtures (scripts/build-ipa.sh checks).
set -euo pipefail

destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/FixtureReplay"
rm -rf "$destination"
if [ "$CONFIGURATION" != "Debug" ]; then
    exit 0
fi

source="$SRCROOT/Packages/ErosKit/Tests/Fixtures"
mkdir -p "$destination"
for item in eh ex constructed manifest.json; do
    cp -R "$source/$item" "$destination/"
done

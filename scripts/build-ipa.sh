#!/bin/bash
# Build an unsigned IPA. Usage: scripts/build-ipa.sh (no arguments)
# Output: build/ipa/Eros.ipa. Exit codes: 0 ok, 64 bad usage, other non-zero = a step failed (1 when the Release app
# carries test hooks).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/build-ipa.sh" >&2
  exit 64
fi

scripts/generate.sh

archive="build/Eros.xcarchive"
mkdir -p build

# Archive without any code signing; the IPA is re-signed by the user's own tool.
xcodebuild archive \
  -project Eros.xcodeproj -scheme Eros -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# Rebuild the IPA layout from scratch: Payload/Eros.app zipped as Eros.ipa.
rm -rf build/ipa
mkdir -p build/ipa/Payload
ditto "$archive/Products/Applications/Eros.app" build/ipa/Payload/Eros.app

scripts/check-release-app.sh build/ipa/Payload/Eros.app
(cd build/ipa && zip -qry Eros.ipa Payload)

echo "IPA: $(pwd)/build/ipa/Eros.ipa"

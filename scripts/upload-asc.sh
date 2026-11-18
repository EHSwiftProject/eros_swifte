#!/bin/bash
# Archive a signed Release build and upload it to App Store Connect, where it is submitted for notarization
# (distribution outside the App Store). Usage: scripts/upload-asc.sh (no arguments)
#
# Environment:
#   EROS_TEAM_ID       Apple Developer team ID (required).
#   EROS_BUILD_NUMBER  CFBundleVersion of this upload (default: UTC time as yyyymmdd.HHMM, unique per upload).
#   ASC_KEY_ID, ASC_ISSUER_ID
#                      An App Store Connect API key; its .p8 is read from ASC_KEY_PATH (default
#                      ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8). Without a key, the account signed in
#                      to Xcode is used.
#
# Signing is automatic with -allowProvisioningUpdates: the archive is signed for development, the export re-signs it
# for distribution (cloud-managed certificate). The unsigned IPA (scripts/build-ipa.sh) is untouched.
# Exit codes: 0 uploaded, 64 bad usage, 1 the Release app carries test hooks, other non-zero = a step failed.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/upload-asc.sh" >&2
  exit 64
fi

team="${EROS_TEAM_ID:-}"
if [ -z "$team" ]; then
  echo "EROS_TEAM_ID is required (your Apple Developer team ID)" >&2
  exit 64
fi
build="${EROS_BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"

auth=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  if [ -z "${ASC_ISSUER_ID:-}" ]; then
    echo "ASC_ISSUER_ID is required with ASC_KEY_ID" >&2
    exit 64
  fi
  key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  if [ ! -f "$key_path" ]; then
    echo "no App Store Connect API key at $key_path" >&2
    exit 64
  fi
  auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

scripts/generate.sh

out="build/upload"
archive="$out/Eros.xcarchive"
rm -rf "$out"
mkdir -p "$out"

# ${auth[@]+...}: macOS bash 3.2 treats an empty array as unbound under set -u.
xcodebuild archive \
  -project Eros.xcodeproj -scheme Eros -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$build"

scripts/check-release-app.sh "$archive/Products/Applications/Eros.app"

# manageAppVersionAndBuildNumber is off so the uploaded build keeps $build, which the AltStore source has to repeat.
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

version="$(plutil -extract CFBundleShortVersionString raw "$archive/Products/Applications/Eros.app/Info.plist")"
echo "uploaded: Eros $version ($build)"

#!/usr/bin/env bash
# Archive the iOS app, sign it for the App Store, and upload it to TestFlight.
#
# Needs an App Store Connect API key in ~/.appstoreconnect/private_keys/ and
# an app record for the bundle ID in App Store Connect — the public API cannot
# create app records, so the first one is made once by hand (or with
# `fastlane produce`, which needs an Apple ID sign-in).
#
# Usage: scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="${ASC_API_KEY_ID:-8BTRQ6P2YQ}"
ISSUER_ID="${ASC_ISSUER_ID:-d543c968-1d53-4a5c-b447-7470b4c36505}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ARCHIVE=build-archive/SwimSyncMobile.xcarchive

[ -f "$KEY_PATH" ] || { echo "✗ API key not found at $KEY_PATH"; exit 1; }

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID")

echo "→ Generating project"
xcodegen generate > /dev/null

# Build numbers must be unique per upload; stamp one from the clock so a
# re-run never collides with a build App Store Connect already has.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "→ Archiving (Release, build $BUILD_NUMBER)"
rm -rf build-archive
xcodebuild -project SwimSync.xcodeproj -scheme SwimSyncMobile -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${AUTH[@]}" archive 2>&1 | grep -E 'error:|ARCHIVE (SUCCEEDED|FAILED)'

cat > build-archive/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>U3972W2GDJ</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><true/>
</dict>
</plist>
PLIST

echo "→ Exporting and uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build-archive/export \
    -exportOptionsPlist build-archive/ExportOptions.plist \
    "${AUTH[@]}" 2>&1 | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)|Upload'

echo "✓ Uploaded. Apple emails when processing finishes (usually a few minutes); then it appears in the TestFlight app."

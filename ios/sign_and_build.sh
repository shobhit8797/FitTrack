#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/FitTrack.xcodeproj"
SCHEME="FitTrack"
CONFIGURATION="Release"
OUTPUT_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$OUTPUT_DIR/FitTrack.xcarchive"
IPA_DIR="$OUTPUT_DIR/IPA"
EXPORT_PLIST="$PROJECT_DIR/ExportOptions.plist"

TEAM_ID="7MFYAGK3VV"
BUNDLE_ID="com.shobhit.fittrack"
API_KEY_ID="GQ653NHYST"
API_KEY_SRC="$HOME/Downloads/AuthKey_${API_KEY_ID}.p8"
API_KEY_DIR="$HOME/.appstoreconnect/private_keys"
API_KEY_DEST="$API_KEY_DIR/AuthKey_${API_KEY_ID}.p8"

echo "==> Installing App Store Connect API key..."
if [ ! -f "$API_KEY_DEST" ]; then
    if [ ! -f "$API_KEY_SRC" ]; then
        echo "ERROR: API key not found at $API_KEY_SRC"
        exit 1
    fi
    mkdir -p "$API_KEY_DIR"
    chmod 700 "$API_KEY_DIR"
    cp "$API_KEY_SRC" "$API_KEY_DEST"
    chmod 600 "$API_KEY_DEST"
    echo "  Copied to $API_KEY_DEST"
else
    echo "  Already present at $API_KEY_DEST"
fi

echo "==> Verifying Distribution certificate..."
security find-identity -v -p codesigning | grep "Apple Distribution.*7MFYAGK3VV" || {
    echo "ERROR: Apple Distribution certificate not found for team 7MFYAGK3VV."
    exit 1
}

mkdir -p "$OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" "$IPA_DIR"

echo ""
echo "==> Archiving FitTrack for App Store / TestFlight..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$OUTPUT_DIR/DerivedData" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$API_KEY_DEST" \
    -authenticationKeyID "$API_KEY_ID" \
    -authenticationKeyIssuerID "263d00d5-4518-4789-886d-018f6c735afe" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    2>&1 | tee "$OUTPUT_DIR/build.log" \
    | grep -E "^(Build|Archive|Compile|Link|Sign|Copy|error:|warning:|\*\*)" || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo ""
    echo "ERROR: Archive not found. Check $OUTPUT_DIR/build.log for details."
    exit 1
fi

echo ""
echo "==> Exporting and uploading to App Store Connect / TestFlight..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$IPA_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$API_KEY_DEST" \
    -authenticationKeyID "$API_KEY_ID" \
    -authenticationKeyIssuerID "263d00d5-4518-4789-886d-018f6c735afe" \
    2>&1 | tee -a "$OUTPUT_DIR/build.log" \
    | grep -E "(Export|Upload|error:|warning:|\*\*)" || true

echo ""
echo "============================================"
echo "  Done! Check App Store Connect > TestFlight"
echo "  appstoreconnect.apple.com"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Go to appstoreconnect.apple.com -> FitTrack -> TestFlight"
echo "  2. Build appears in ~15 min (Apple processes it)"
echo "  3. Add External Testers -> New Group -> Public Link"
echo "  4. Share the link — anyone installs TestFlight app then FitTrack"

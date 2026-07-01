#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION="0.3.1"
APP_NAME="ainstype"
BUNDLE_NAME="${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
# Override with your own when building from a fork:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID ./build_app.sh
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Soon Up GmbH (6A2SZH3VT5)}"
TEAM_ID="${TEAM_ID:-6A2SZH3VT5}"
ENTITLEMENTS="Entitlements.plist"
INFO_PLIST="Info.plist"

BUILD_DIR=".build/release"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${BUNDLE_NAME}"

echo "=== Building ${APP_NAME} (release) ==="
swift build -c release --arch arm64

if [ ! -f "${BUILD_DIR}/AinstypeApp" ]; then
    echo "ERROR: ${BUILD_DIR}/AinstypeApp not found"
    exit 1
fi

echo ""
echo "=== Creating .app bundle ==="

rm -rf "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/AinstypeApp" "${APP_DIR}/Contents/MacOS/AinstypeApp"

# Copy Info.plist
cp "${INFO_PLIST}" "${APP_DIR}/Contents/Info.plist"

# Copy app icon
cp "AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# Bundle WhisperKit model (eliminates first-run download)
BUNDLE_MODEL="${BUNDLE_MODEL:-ask}"
MODEL_NAME="openai_whisper-large-v3-v20240930_turbo_632MB"
MODEL_CACHE="${HOME}/Documents/huggingface/models/argmaxinc/whisperkit-coreml/${MODEL_NAME}"

if [ "${BUNDLE_MODEL}" = "ask" ]; then
    read -p "Bundle WhisperKit model (~616MB)? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        BUNDLE_MODEL="no"
    else
        BUNDLE_MODEL="yes"
    fi
fi

if [ "${BUNDLE_MODEL}" = "yes" ]; then
    if [ -d "${MODEL_CACHE}" ]; then
        echo "Bundling WhisperKit model from cache..."
        MODEL_DEST="${APP_DIR}/Contents/Resources/Models/${MODEL_NAME}"
        mkdir -p "${MODEL_DEST}"
        cp -R "${MODEL_CACHE}/"* "${MODEL_DEST}/"
        MODEL_SIZE=$(du -sh "${MODEL_DEST}" | cut -f1)
        echo "Model size: ${MODEL_SIZE}"
    else
        echo "ERROR: Model not found at ${MODEL_CACHE}"
        echo "Run the app once to download the model, then rebuild."
        exit 1
    fi
else
    echo "Skipping model bundle — users will download on first run."
fi

BINARY_SIZE=$(du -sh "${APP_DIR}/Contents/MacOS/AinstypeApp" | cut -f1)
echo "Binary size: ${BINARY_SIZE}"

echo ""
echo "=== Code signing ==="

if ! security find-identity -v -p codesigning | grep -q "${IDENTITY}"; then
    echo "ERROR: signing identity not found in keychain:"
    echo "  ${IDENTITY}"
    echo "Set your own when building from a fork (see top of this script):"
    echo "  SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' TEAM_ID=TEAMID ./build_app.sh"
    echo "List available identities with: security find-identity -v -p codesigning"
    exit 1
fi

codesign --force --deep --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${IDENTITY}" \
    "${APP_DIR}"

codesign --verify --deep --strict "${APP_DIR}"
echo "Signature OK"

echo ""
echo "=== Creating ${DMG_NAME} ==="

rm -f "${DMG_NAME}"

if command -v create-dmg &> /dev/null; then
    create-dmg \
        --volname "${APP_NAME}" \
        --app-drop-link 400 185 \
        --window-pos 200 120 \
        --window-size 600 400 \
        --hide-extension "${BUNDLE_NAME}" \
        "${DMG_NAME}" \
        "${APP_DIR}"
else
    echo "(install create-dmg for a nicer DMG: brew install create-dmg)"
    hdiutil create -srcfolder "${APP_DIR}" \
        -volname "${APP_NAME}" \
        -fs HFS+ \
        -format UDZO \
        "${DMG_NAME}"
fi

echo ""
echo "=== Notarizing ==="
echo "(Requires keychain profile 'ainstype-notary')"
echo "Store credentials with:"
echo "  xcrun notarytool store-credentials 'ainstype-notary' \\"
echo "    --apple-id YOUR_APPLE_ID --team-id ${TEAM_ID} --password APP_SPECIFIC_PASSWORD"
echo ""

read -p "Notarize now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    xcrun notarytool submit "${DMG_NAME}" \
        --keychain-profile "ainstype-notary" \
        --wait

    echo ""
    echo "=== Stapling ==="
    xcrun stapler staple "${DMG_NAME}"
fi

echo ""
echo "=== Done ==="
echo "App: $(pwd)/${APP_DIR}"
echo "DMG: $(pwd)/${DMG_NAME}"
echo ""
echo "Binary size: ${BINARY_SIZE}"
echo "To test: open ${APP_DIR}"

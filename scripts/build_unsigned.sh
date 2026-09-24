#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to a full Xcode 26+ installation on the build host}"
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null; then
  echo "Missing iOS SDK. Run this script on the cloud macOS build host." >&2
  exit 1
fi
python3 scripts/prepare_dependencies.py
.tools/xcodegen/bin/xcodegen generate --spec project.yml
mkdir -p build
xcodebuild -version > build/toolchain.txt
xcrun --sdk iphoneos --show-sdk-version >> build/toolchain.txt
xcodebuild -project VoiceBench.xcodeproj -scheme VoiceBench \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" build 2>&1 | tee build/build.log
APP=build/DerivedData/Build/Products/Release-iphoneos/VoiceBench.app
test -d "$APP"
python3 scripts/package_ipa.py "$APP" build/VoiceBench-unsigned.ipa
shasum -a 256 build/VoiceBench-unsigned.ipa > build/VoiceBench-unsigned.ipa.sha256
echo "Unsigned IPA ready; sign with your own account before installing."

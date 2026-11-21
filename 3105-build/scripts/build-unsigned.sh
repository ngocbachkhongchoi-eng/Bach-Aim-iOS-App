#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'Build blocked: this script requires macOS with full Xcode and an iPhoneOS SDK.' >&2
  exit 2
fi
build_root="$(mktemp -d "${TMPDIR:-/tmp}/3105-build.XXXXXX")"
mkdir -p artifacts "$build_root/package/Payload"
xcodebuild -version
echo "Running document-import checks"
python3 -u scripts/test-document-import.py 2>&1 | tee artifacts/test-document-import.log
echo "Running cache-import checks"
python3 -u scripts/test-cache-import.py 2>&1 | tee artifacts/test-cache-import.log
echo "Running offline-key checks"
python3 -u scripts/test-offline-key.py 2>&1 | tee artifacts/test-offline-key.log
sips -z 1024 1024 ThreeOneOSFive/Assets.xcassets/BigVipLogo.imageset/Logo.png --out ThreeOneOSFive/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
xcodebuild -project ThreeOneOSFive.xcodeproj -target 3105 \
  -configuration Release -sdk iphoneos -arch arm64 \
  SYMROOT="$build_root/products" OBJROOT="$build_root/objects" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build 2>&1 | tee artifacts/build.log
app="$build_root/products/Release-iphoneos/3105.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Info.plist")" = bigvip
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
test -f "$app/$executable"
xcrun lipo "$app/$executable" -verify_arch arm64
ditto "$app" "$build_root/package/Payload/3105.app"
ditto -c -k --keepParent "$build_root/package/Payload" artifacts/big.ipa
unzip -t artifacts/big.ipa
shasum -a 256 artifacts/big.ipa > artifacts/SHA256SUMS.txt
echo 'Created unsigned IPA; signing and on-device verification still required.'

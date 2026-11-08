#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin ]]; then echo 'Requires macOS and Xcode.' >&2; exit 1; fi
bash ios/scripts/build-go.sh device
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/MusicDL.xcodeproj -scheme MusicDL -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath ios/build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  PRODUCT_BUNDLE_IDENTIFIER="${IOS_APP_ID:-com.guohuiyuan.musicdl.nativepreview}" build
app="$PWD/ios/build/DerivedData/Build/Products/Release-iphoneos/MusicDL.app"
plist="$app/Info.plist"
plutil -lint "$plist"
[[ "$(plutil -extract UIBackgroundModes.0 raw -o - "$plist")" == audio ]]
[[ " $(lipo -archs "$app/MusicDL") " == *' arm64 '* ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" == "${IOS_APP_ID:-com.guohuiyuan.musicdl.nativepreview}" ]]
codesign --remove-signature "$app" 2>/dev/null || true
mkdir -p ios/build/Package/Payload
ditto "$app" ios/build/Package/Payload/MusicDL.app
output="$PWD/music-dl-ios-native-unsigned.ipa"
rm -f "$output"
(cd ios/build/Package && zip -qry "$output" Payload)
unzip -tq "$output"
shasum -a 256 music-dl-ios-native-unsigned.ipa > music-dl-ios-native-unsigned.ipa.sha256
git rev-parse HEAD > music-dl-ios-native-source.txt
cp LICENSE music-dl-ios-native-LICENSE.txt
echo 'Unsigned IPA prepared for SideStore re-signing. Device acceptance is still required.'

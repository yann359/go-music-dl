#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
kind="${1:-device}"
case "$kind" in
  device) sdk=iphoneos; target=arm64-apple-ios15.0 ;;
  simulator) sdk=iphonesimulator; target=arm64-apple-ios15.0-simulator ;;
  *) echo "Expected device or simulator" >&2; exit 1 ;;
esac
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
compiler="$(xcrun --sdk "$sdk" --find clang)"
mkdir -p "ios/build/$kind"
# CC is a wrapper to preserve paths containing spaces and the simulator triple.
wrapper="$PWD/ios/build/$kind/clang.sh"
printf '#!/usr/bin/env bash\nexec %q -target %q -isysroot %q "$@"\n' "$compiler" "$target" "$sdk_path" > "$wrapper"
chmod +x "$wrapper"
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$wrapper"
go build -trimpath -buildmode=c-archive -o "ios/build/$kind/libmusicdl.a" ./ios/bridge

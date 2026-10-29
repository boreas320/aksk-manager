#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEAM=${AKSK_DEVELOPMENT_TEAM:-XHD2S8GC8Q}
xcodebuild -project "$ROOT/native/AKSKHelper.xcodeproj" -scheme AKSKHelper \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/xcode" DEVELOPMENT_TEAM="$TEAM" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
APP="$ROOT/.build/xcode/Build/Products/Release/AKSKHelper.app"
/usr/bin/codesign --verify --strict "$APP"
test -f "$APP/Contents/embedded.provisionprofile"
mkdir -p "$ROOT/runtime"
# ditto preserves the app signature and its provisioning profile.
/usr/bin/ditto "$APP" "$ROOT/runtime/AKSKHelper.app"
echo '已构建签名组件。下一步运行 scripts/smoke-keychain.py 验证本机读写。'

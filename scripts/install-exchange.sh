#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -project "$ROOT/native/Exchange.xcodeproj" -scheme 'AKSK Manager' \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$ROOT/.build/exchange" \
  DEVELOPMENT_TEAM="${AKSK_DEVELOPMENT_TEAM:-XHD2S8GC8Q}" -allowProvisioningUpdates build
APP="$ROOT/.build/exchange/Build/Products/Release/AKSK Manager.app"
for bundle in "$APP" "$APP/Contents/PlugIns/AKSKProvider.appex"; do
  codesign --verify --strict "$bundle"
  test -f "$bundle/Contents/embedded.provisionprofile"
done
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/AKSK Manager.app"
open "$HOME/Applications/AKSK Manager.app"

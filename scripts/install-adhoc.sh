#!/bin/bash
set -euo pipefail
SRC="${1:?path to DerivedData/.../Debug/AirBattery.app}"
DST="${HOME}/Applications/AirBattery.app"
DD="$(cd "$SRC/../../.." && pwd)"
APP_XCENT=$(find "$DD/Intermediates.noindex" -name 'AirBattery.app.xcent' 2>/dev/null | head -1 || true)
WID_XCENT=$(find "$DD/Intermediates.noindex" -name 'AirBatteryWidgetExtension.appex.xcent' 2>/dev/null | head -1 || true)
HELPER_XCENT=$(find "$DD/Intermediates.noindex" -name 'AirBatteryHelper.app.xcent' 2>/dev/null | head -1 || true)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "APP_XCENT=$APP_XCENT"
echo "WID_XCENT=$WID_XCENT"

osascript -e 'tell application "AirBattery" to quit' 2>/dev/null || true
killall AirBattery AirBatteryWidgetExtension 2>/dev/null || true
sleep 1
rm -rf "$DST"
mkdir -p "$HOME/Applications"
cp -R "$SRC" "$DST"
xattr -cr "$DST" 2>/dev/null || true

# NEVER codesign --deep without entitlements — strips app-sandbox and breaks
# widget documentDirectory (empty 8-ring widget).
if [[ -n "${WID_XCENT}" ]]; then
  codesign --force --sign - --entitlements "$WID_XCENT" \
    "$DST/Contents/PlugIns/AirBatteryWidgetExtension.appex"
else
  codesign --force --sign - --entitlements "$ROOT/widget/widget.entitlements" \
    "$DST/Contents/PlugIns/AirBatteryWidgetExtension.appex"
fi
if [[ -d "$DST/Contents/Library/LoginItems/AirBatteryHelper.app" ]]; then
  if [[ -n "${HELPER_XCENT}" ]]; then
    codesign --force --sign - --entitlements "$HELPER_XCENT" \
      "$DST/Contents/Library/LoginItems/AirBatteryHelper.app" || true
  else
    codesign --force --sign - "$DST/Contents/Library/LoginItems/AirBatteryHelper.app" || true
  fi
fi
if [[ -n "${APP_XCENT}" ]]; then
  codesign --force --sign - --entitlements "$APP_XCENT" "$DST"
else
  codesign --force --sign - --entitlements "$ROOT/AirBattery/AirBattery.entitlements" "$DST"
fi

echo '==== post-sign widget entitlements ===='
codesign -d --entitlements - "$DST/Contents/PlugIns/AirBatteryWidgetExtension.appex" 2>&1 | head -30
open "$DST"

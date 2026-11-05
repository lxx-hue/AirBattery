#!/bin/bash
# Build with the PrivateWidgetKit interface overlay (exposes WidgetKit SPI
# chronod caches widget descriptors per CFBundleVersion: bump it every build,
# otherwise preferredBackgroundStyle changes are ignored (descriptor stays 0).
# WidgetConfiguration.preferredBackgroundStyle(.blur), as used by Apple's Batteries widget).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -project AirBattery.xcodeproj -scheme AirBattery -configuration Debug \
  MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGN_IDENTITY=- \
  SWIFT_INCLUDE_PATHS="$ROOT/PrivateWidgetKit" \
  CURRENT_PROJECT_VERSION="${AB_BUILD:-$(date +%y%m%d%H%M)}" build

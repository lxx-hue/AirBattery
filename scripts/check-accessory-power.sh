#!/bin/bash
# Static checks: the private accessory listener must stay removed, and the
# installed custom tree must stay. This does not run on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ ! -e AirBattery/BatteryInfo/AccessoryPowerMonitor.swift ]] || fail "private listener file is back"

if rg -n --glob '*.swift' 'accpowersources|IOPSCopyPowerSourcesByType|notify_register_dispatch|IOPSAccNotificationCreateRunLoopSource|kIOPSSourceForAccessories' AirBattery widget; then
  fail "private accessory power API is still referenced"
fi

rg -q 'onlyIfChanged' AirBattery/BatteryInfo/MagicBattery.swift && fail "HID scan signature was left modified"
rg -q 'func getMagicBattery\(\)' AirBattery/BatteryInfo/MagicBattery.swift || fail "baseline getMagicBattery missing"
rg -q 'Timer.publish\(every: 1' AirBattery/Supports/Supports.swift || fail "mainTimer cadence changed"
rg -q 'onReceive\(mainTimer\)' AirBattery/ViewModel/BatteryView.swift || fail "status-bar battery subscription missing"
rg -q 'InternalBattery.status = getPowerState\(\)' AirBattery/ViewModel/BatteryView.swift || fail "1s getPowerState call missing"
rg -q 'widgetViewTimer = Timer.publish\(every: TimeInterval\(60 \* updateInterval\)' AirBattery/Supports/Supports.swift || fail "widget timer cadence changed"
rg -q 'TimeInterval\(60 \* max\(1, updateInterval\)\)' AirBattery/Supports/AirBatteryApp.swift || fail "widget JSON timer cadence changed"
rg -q 'refreshWidgetData\(includeIDevices: true, refreshBluetooth: false, reloadWidgets: false\)' AirBattery/Supports/AirBatteryApp.swift || fail "60s timer flags changed"
rg -q 'let interval = TimeInterval\(29 \* updateInterval\)' AirBattery/BatteryInfo/BLEBattery.swift || fail "BLE scan interval changed"
rg -q 'No 2A19 notify subscription' AirBattery/BatteryInfo/BLEBattery.swift || fail "K580/BLE read cadence comment removed"
rg -q 'readConnectedBatteryPeripherals' AirBattery/BatteryInfo/BLEBattery.swift || fail "connected BLE keyboard read removed"
rg -q 'if age > Double\(60 \* updateInterval\)' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi iDevice interval changed"
rg -q 'arguments: \["-n"\], timeout: 30' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi discovery timeout changed"
rg -q 'comptest' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Watch lockdown read removed"
rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com.lihaoyun6.AirBattery;' AirBattery.xcodeproj/project.pbxproj || fail "bundle id changed"
rg -q 'startingUpdater: false' AirBattery/Supports/AirBatteryApp.swift || fail "updater was re-enabled"
rg -q 'Update section removed' AirBattery/ViewModel/SettingsView.swift || fail "settings update section returned"
rg -q 'preferredBackgroundStyle\(\.blur\)' widget/widgetBundle.swift || fail "widget glass background removed"
rg -q 'PrivateWidgetKit' scripts/build.sh || fail "PrivateWidgetKit build hook removed"
rg -q 'MACOSX_DEPLOYMENT_TARGET=12.0' scripts/build.sh || fail "deployment target override removed"
rg -q 'CURRENT_PROJECT_VERSION' scripts/build.sh || fail "build number bump removed"
rg -q 'widget/widget.entitlements' scripts/install-adhoc.sh || fail "widget entitlement re-sign removed"
[[ -f PrivateWidgetKit/README.md ]] || fail "PrivateWidgetKit removed"

echo "static checks ok: private accessory listener absent, baseline customizations present"

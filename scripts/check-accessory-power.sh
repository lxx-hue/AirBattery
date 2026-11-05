#!/bin/bash
# Static checks for the public Mac/mouse power notifications and the custom
# baseline. This does not compile or run on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f AirBattery/BatteryInfo/LocalPowerNotifications.swift ]] || fail "local power notification file missing"

if rg -n --glob '*.swift' 'accpowersources|IOPSCopyPowerSourcesByType|notify_register_dispatch|IOPSAccNotificationCreateRunLoopSource|kIOPSSourceForAccessories|62747374' AirBattery widget; then
  fail "private accessory API or hardcoded interest message is present"
fi

rg -q 'IOPSNotificationCreateRunLoopSource' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "public Mac power source notification missing"
rg -q 'NSProcessInfoPowerStateDidChange' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "low power mode notification missing"
rg -q 'kIOGeneralInterest' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "public general interest missing"
rg -q 'kIOFirstMatchNotification' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "service appear notification missing"
rg -q 'kIOTerminatedNotification' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "service disappear notification missing"
if rg -n 'IOPSCreateLimitedPowerNotification\(' AirBattery widget; then
  fail "AC-only power notification must not be the listener"
fi
if rg -n 'IDeviceBattery|BLEBattery|refreshWidgetData|scanDevicesNow|idevice_' AirBattery/BatteryInfo/LocalPowerNotifications.swift; then
  fail "local power notification reaches phone, BLE, or widget scan"
fi

rg -q 'func getMagicBattery\(\)' AirBattery/BatteryInfo/MagicBattery.swift || fail "baseline getMagicBattery missing"
rg -q 'publishIfChanged' AirBattery/BatteryInfo/MagicBattery.swift || fail "mouse interest write is not gated on change"
rg -F -q 'if status == 4 { status = 0 }' AirBattery/BatteryInfo/MagicBattery.swift || fail "BatteryStatusFlags mapping removed"
rg -q 'func sameBattery\(' AirBattery/BatteryInfo/AirBatteryModel.swift || fail "duplicate-device comparison missing"
rg -q 'mouseQuietSeconds' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "mouse debounce missing"
rg -q 'scheduleLocalPowerWidgetReload' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "throttled widget reload missing"
rg -q 'widgetInterval != -1' AirBattery/BatteryInfo/LocalPowerNotifications.swift || fail "disabled widget refresh is not honored"

rg -q 'Timer.publish\(every: 1' AirBattery/Supports/Supports.swift || fail "mainTimer cadence changed"
rg -q 'onReceive\(mainTimer\)' AirBattery/ViewModel/BatteryView.swift || fail "status-bar battery subscription missing"
if rg -n 'getPowerState\(\)' AirBattery/ViewModel/BatteryView.swift; then
  fail "status bar still reads IOKit on the one-second timer"
fi
rg -q 'widgetViewTimer = Timer.publish\(every: TimeInterval\(60 \* updateInterval\)' AirBattery/Supports/Supports.swift || fail "widget timer cadence changed"
rg -q 'TimeInterval\(60 \* max\(1, updateInterval\)\)' AirBattery/Supports/AirBatteryApp.swift || fail "widget JSON timer cadence changed"
rg -q 'refreshWidgetData\(includeIDevices: true, refreshBluetooth: false, reloadWidgets: false\)' AirBattery/Supports/AirBatteryApp.swift || fail "60s timer flags changed"
rg -q 'let interval = TimeInterval\(29 \* updateInterval\)' AirBattery/BatteryInfo/BLEBattery.swift || fail "BLE scan interval changed"
rg -q 'No 2A19 notify subscription' AirBattery/BatteryInfo/BLEBattery.swift || fail "K580/BLE read cadence comment removed"
rg -q 'readConnectedBatteryPeripherals' AirBattery/BatteryInfo/BLEBattery.swift || fail "connected BLE keyboard read removed"
rg -q 'if age > Double\(60 \* updateInterval\)' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi iDevice interval changed"
rg -q 'arguments: \["-n"\], timeout: 30' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi discovery timeout changed"
rg -q 'comptest' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Watch lockdown read removed"
rg -q 'MacPowerNotifications.shared.start\(\)' AirBattery/Supports/AirBatteryApp.swift || fail "Mac power listener is not started"
rg -q 'MousePowerInterest.shared.start\(\)' AirBattery/Supports/AirBatteryApp.swift || fail "mouse interest listener is not started"
rg -q 'MousePowerInterest.shared.stop\(\)' AirBattery/Supports/AirBatteryApp.swift || fail "mouse interest listener is not stopped"
rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com.lihaoyun6.AirBattery;' AirBattery.xcodeproj/project.pbxproj || fail "bundle id changed"
rg -q 'A1B2C0032E11000100AB1001' AirBattery.xcodeproj/project.pbxproj || fail "notification source file is not in the app target"
rg -q 'startingUpdater: false' AirBattery/Supports/AirBatteryApp.swift || fail "updater was re-enabled"
rg -q 'Update section removed' AirBattery/ViewModel/SettingsView.swift || fail "settings update section returned"
rg -q 'preferredBackgroundStyle\(\.blur\)' widget/widgetBundle.swift || fail "widget glass background removed"
rg -q 'PrivateWidgetKit' scripts/build.sh || fail "PrivateWidgetKit build hook removed"
rg -q 'MACOSX_DEPLOYMENT_TARGET=12.0' scripts/build.sh || fail "deployment target override removed"
rg -q 'CURRENT_PROJECT_VERSION' scripts/build.sh || fail "build number bump removed"
rg -q 'widget/widget.entitlements' scripts/install-adhoc.sh || fail "widget entitlement re-sign removed"
[[ -f PrivateWidgetKit/README.md ]] || fail "PrivateWidgetKit removed"

echo "static checks ok: public Mac/mouse notifications present, private APIs absent, baseline customizations present"

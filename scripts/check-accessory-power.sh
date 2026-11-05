#!/bin/bash
# Static checks that do not need a Mac. They do not prove runtime notify
# delivery, widget refresh latency, or power use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MON="AirBattery/BatteryInfo/AccessoryPowerMonitor.swift"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$MON" ]] || fail "missing $MON"
# Full-line comments may name APIs the monitor refuses to call.
CODE="$(grep -v -E '^[[:space:]]*//' "$MON")"

# Only the accessory notify names may appear. Public main-battery names must not.
mapfile -t names < <(printf '%s\n' "$CODE" | grep -oE 'com\.apple\.system\.[A-Za-z0-9.]+' | sort -u)
expected=$'com.apple.system.accpowersources.attach\ncom.apple.system.accpowersources.source\ncom.apple.system.accpowersources.timeremaining'
actual="$(printf '%s\n' "${names[@]}")"
[[ "$actual" == "$expected" ]] || fail "notify names drifted:
$actual"

printf '%s\n' "$CODE" | grep -q 'IOPSNotificationCreateRunLoopSource' && fail "must not call the main-battery runloop source"
printf '%s\n' "$CODE" | grep -q 'IOPSCreateLimitedPowerNotification' && fail "must not call the limited-power runloop source"
printf '%s\n' "$CODE" | grep -q 'idevice' && fail "accessory monitor must not query iPhone/iPad/Watch"
printf '%s\n' "$CODE" | grep -q 'comptest' && fail "accessory monitor must not query Watch"
printf '%s\n' "$CODE" | grep -q 'system_profiler' && fail "accessory monitor must not launch system_profiler"
printf '%s\n' "$CODE" | grep -q 'scanForPeripherals' && fail "accessory monitor must not start a BLE scan"
grep -q 'category == "Watch"' "$MON" || fail "Watch category must be skipped"
grep -q 'protectedDeviceTypes' "$MON" || fail "protected device types missing"
grep -q '"Mouse", "Keyboard", "Trackpad"' "$MON" || fail "allowed categories missing"
grep -q 'accessorySourceType: Int32 = 4' "$MON" || fail "accessory source type must stay 4"
grep -q 'dlsym' "$MON" || fail "IOPSCopyPowerSourcesByType must be resolved dynamically"

# Existing cadences stay put.
grep -q 'Timer.publish(every: 1' AirBattery/Supports/Supports.swift || fail "mainTimer cadence changed"
grep -q 'widgetViewTimer = Timer.publish(every: TimeInterval(60 \* updateInterval)' AirBattery/Supports/Supports.swift || fail "widget timer cadence changed"
grep -q 'TimeInterval(60 \* max(1, updateInterval))' AirBattery/Supports/AirBatteryApp.swift || fail "widget JSON timer cadence changed"
grep -q 'refreshWidgetData(includeIDevices: true, refreshBluetooth: false, reloadWidgets: false)' AirBattery/Supports/AirBatteryApp.swift || fail "60s timer flags changed"
grep -q 'let interval = TimeInterval(29 \* updateInterval)' AirBattery/BatteryInfo/BLEBattery.swift || fail "BLE scan interval changed"
grep -q 'No 2A19 notify subscription' AirBattery/BatteryInfo/BLEBattery.swift || fail "K580/BLE read cadence comment removed"
grep -q 'readConnectedBatteryPeripherals' AirBattery/BatteryInfo/BLEBattery.swift || fail "connected BLE keyboard read removed"
grep -q 'if age > Double(60 \* updateInterval)' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi iDevice interval changed"
grep -q 'arguments: \["-n"\], timeout: 30' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Wi-Fi discovery timeout changed"
grep -q 'comptest' AirBattery/BatteryInfo/IDeviceBattery.swift || fail "Watch lockdown read removed"

# Installed customizations still present.
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.lihaoyun6.AirBattery;' AirBattery.xcodeproj/project.pbxproj || fail "bundle id changed"
grep -q 'startingUpdater: false' AirBattery/Supports/AirBatteryApp.swift || fail "updater was re-enabled"
grep -q 'Update section removed' AirBattery/ViewModel/SettingsView.swift || fail "settings update section returned"
grep -q 'preferredBackgroundStyle(.blur)' widget/widgetBundle.swift || fail "widget glass background removed"
grep -q 'MACOSX_DEPLOYMENT_TARGET=12.0' scripts/build.sh || fail "deployment target override removed"
grep -q 'CURRENT_PROJECT_VERSION' scripts/build.sh || fail "build number bump removed"
grep -q 'widget/widget.entitlements' scripts/install-adhoc.sh || fail "widget entitlement re-sign removed"
grep -q 'AccessoryPowerMonitor.shared.start()' AirBattery/Supports/AirBatteryApp.swift || fail "monitor is not started"
grep -q 'AccessoryPowerMonitor.shared.stop()' AirBattery/Supports/AirBatteryApp.swift || fail "monitor is not stopped"
grep -q 'A1ACC0012F00000100A78DF6' AirBattery.xcodeproj/project.pbxproj || fail "monitor is not in the app target"

python3 scripts/test_accessory_rules.py
echo "static accessory-power checks ok"

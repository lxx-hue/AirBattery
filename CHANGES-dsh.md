# AirBattery changes

Round 1 was committed as `21655a3` on branch `dsh-patch` (base
`134e02f2861f933b862b2b6a9562a7f55e505e97`). The Round 2 fixes below are
uncommitted in the working tree. All code changes are in existing source files;
`AirBattery.xcodeproj` was not touched.

## 1. #175 — Settings window on macOS 14+/26

**Files:** `AirBattery/Supports/AirBatteryApp.swift`, `AirBattery/ViewModel/ContentView.swift`

**What changed**

- Added `SettingsWindowState` (in `AirBatteryApp.swift`). It keeps a weak reference to
  the Settings scene window, activates the app, makes that window key and orders it
  front, and temporarily promotes an accessory (`LSUIElement`) app to `.regular`
  while Settings is open so the window can come to the front. The previous
  activation policy is restored when the Settings window closes (via both the
  `WindowAccessor` close callback and an `NSWindow.willCloseNotification`
  observer, so losing the delegate does not leave a permanent Dock icon), or
  after a 2-second grace period if no window ever appeared.
- Replaced the fragile fixed-index menu lookup
  (`NSApp.mainMenu?.items.first?.submenu?.item(at: 2)`) in `openSettingPanel()`
  with a recursive search for the menu item whose action is
  `showSettingsWindow:` / `showPreferencesWindow:` (or the conventional
  Cmd-, shortcut), then `performAction()`.
  If no such item is found, macOS 13 falls back to
  `sendAction(showSettingsWindow:)` and macOS 11/12 to
  `showPreferencesWindow:`; macOS 14+ has no selector fallback because that
  action is a no-op there. The window is brought forward asynchronously after
  SwiftUI creates it.
- The popover gear button on macOS 14+ now uses a small `OpenSettingsButton`
  wrapper that calls SwiftUI's `@Environment(\.openSettings)` action, after
  activating the app and closing the popover. If the environment action is not
  available in the `NSHostingController` hosting context (or the scene does not
  appear within 0.3 s), it falls back to `openSettingPanel()`. macOS 11–13 keep
  the previous AppKit button path.
- The Dock menu `Settings...` item (`openSetting`) and
  `applicationShouldHandleReopen` already called `openSettingPanel()` upstream;
  they now share the same improved helper as the popover gear.

## 2. #215 / #206 / #124 — wake-from-sleep data races

**Files:** `AirBattery/Supports/AirBatteryApp.swift`,
`AirBattery/BatteryInfo/MagicBattery.swift`,
`AirBattery/BatteryInfo/AirBatteryModel.swift`,
`AirBattery/BatteryInfo/InternalBattery.swift`,
`AirBattery/BatteryInfo/BTDBattery.swift`,
`AirBattery/BatteryInfo/IDeviceBattery.swift`,
`AirBattery/Supports/Supports.swift`

**What changed**

- `AppDelegate.deviceIsConnected(...)` now reads `device.name`,
  `device.addressString` and `device.isAppleDevice` on the callback thread and
  captures only those values (`String`, `String`, `Bool`) in the background
  closure. The `IOBluetoothDevice` object is no longer retained or released on a
  background queue.
- Connect handling now runs on a dedicated **serial** `deviceConnectQueue`
  instead of `DispatchQueue.global(qos: .background)`. A reconnect burst after
  wake is processed one device at a time, so `system_profiler` scans cannot pile
  up in parallel.
- `SPBluetoothDataModel.data` (`MagicBattery.swift`) is now an `NSLock`-protected
  computed property around a private `storedData` string. The lock is never held
  while `system_profiler` runs or while the completion handler executes.
- `AirBatteryModel.Devices` is now an `NSLock`-protected computed property around
  a private `storedDevices` array. `updateDevice` takes the lock only for the
  index/append mutation and **no longer drops an update** when another thread is
  already writing (the old `static var lock = false` check is gone).
  `hideDevice`/`unhideDevice` take the same lock. `getAll` copies a snapshot
  under the lock and does all filtering outside it, so no lock is held while
  reading `UserDefaults` or calling `checkIfBlocked`.
- `AirBatteryModel.writeData()` now encodes outside the lock and guards the
  actual file write with a separate `writeLock`. The write is atomic, so the
  widget extension cannot read a partially written `data.json`. `writeData` also
  performs the normal `getAll()` pruning (devices older than the configured
  `disappearTime` are excluded before the JSON is written).
- `InternalBattery.status` (a struct read by background widget/scan code and
  written on the main thread) is now lock-protected.
- `BTDBattery.allDevices` (a static string array written by detached scan threads)
  is now lock-protected; the deduplicating mutation moved into `rememberDevice`.
- `IDeviceBattery` now owns a serial `scanQueue` with coalescing state. Repeated
  timer/button calls cannot start overlapping `ideviceinfo` sessions. Added
  `scanDevicesNow()` for the widget-refresh path, which needs the scan to finish
  before the JSON write. The iDevice commands now have generous bounded
  timeouts (20 s for USB discovery/wificonnection, 30 s for Wi-Fi discovery and
  device/watch info) so a hung `libimobiledevice` process cannot stall the
  serialized refresh queue forever while still allowing normal slow Wi-Fi
  discovery.
- `process(path:arguments:timeout:)` output buffers were audited: every call owns
  its own `Process`, `Pipe` and `Data`; there is no shared output buffer. The
  timeout work item is now cancellable and captures the task weakly, so it
  cannot touch a finished task/pipe after return. SIGKILL escalation uses
  `kill(pid, SIGKILL)` instead of recursively launching `/bin/kill`, removing one
  more concurrent process launch from the timeout path.

## 3. #104 — “Reload All Widgets” and stale iPhone/iPad data

**Files:** `AirBattery/Supports/AirBatteryApp.swift`,
`AirBattery/ViewModel/SettingsView.swift`,
`AirBattery/ViewModel/ContentView.swift`,
`AirBattery/Supports/AppleScript.swift`,
`AirBattery/BatteryInfo/AirBatteryModel.swift`

**What changed**

- Added a single serialized
  `refreshWidgetData(includeIDevices:refreshBluetooth:reloadWidgets:)` path. It:
  1. synchronously refreshes iPhones/iPads (libimobiledevice) when requested,
  2. refreshes the `system_profiler` Bluetooth snapshot,
  3. runs the normal Magic/Bluetooth scan,
  4. calls `AirBatteryModel.writeData()` (which applies the offline-device
     removal window through `getAll()` and writes atomically),
  5. when reloading is requested, only then calls
     `WidgetCenter.shared.reloadAllTimelines()` on the main thread.
- The Settings “Reload All Widgets” button now calls this path with
  `includeIDevices: true`, instead of only rewriting the current in-memory list.
- Added an app-level repeating `Timer` in `AppDelegate` (interval
  `60 * updateInterval` seconds) that re-reads iPhones/iPads and rewrites the
  shared widget JSON even when no popover/dock view is open. It deliberately
  skips the heavier `system_profiler`/Bluetooth scan and does **not** reload
  timelines on every tick; the single existing `widgetViewTimer` remains the
  periodic reload source and still respects the “System Default” setting
  (`widgetInterval == -1`).
- The old `MultiBatteryView` 24-second `widgetDataTimer` path now uses the same
  serialized refresh function instead of doing its own un-serialized
  `system_profiler`/write from the main thread. It skips the iDevice scan
  (`includeIDevices: false`) because the 5-second `dockTimer` already drives it.
- The `airbattery://reloadwingets` URL handler and the AppleScript
  `reload all widgets` command now use the same refresh path.
- The launch-time write/reload also goes through `refreshWidgetData`, so a
  just-connected iPhone/iPad is included in the initial widget data.

## 4. iPhone/iPad path and native-looking widget (review only)

No widget source was changed. I read the iDevice and widget paths after the
changes:

- `IDeviceBattery.getIDeviceBattery()` still runs `idevice_id -n` (Wi-Fi/network),
  `idevice_id -l` (USB/local), `wificonnection`, `ideviceinfo`, and the watch
  `comptest` path with the same arguments. The new serial queue only changes
  when calls run, not what they run. The widget JSON is built from the same
  `Device` records.
- The ring widgets in `widget/BatteryWidget.swift`, `BatteryWidget2.swift` and
  `BatteryWidget3.swift` already use `getPowerColor(item)` (green, yellow at
  ≤20%, red at ≤10%), a centered device glyph, a percentage label, and
  `batt_bolt` when `isCharging != 0`. I found no concrete rendering bug or clear
  deviation that justified a visual edit, so the widget files are untouched.

## Round 2 — review fixes (uncommitted)

### S1 — localized Settings window lookup

**Files:** `AirBattery/Supports/AirBatteryApp.swift`,
`AirBattery/ViewModel/SettingsView.swift`

`findSettingsWindow()` no longer relies on English title substrings. It checks
`NSWindow.identifier?.rawValue` (case-insensitive "settings"/"preferences", which
covers SwiftUI's `com_apple_SwiftUI_Settings_window`), the localized
`NSLocalizedString("AirBattery Settings", comment: "")` title, and the English
title. `restorePolicyIfNoWindow()` now re-runs `retrackWindow()` before demoting
the app, and `SettingsView.onAppear` re-tracks a Settings window that SwiftUI
reused on a second open. Re-tracking also re-installs the close observer.

Not done: the exact identifier/title on every macOS version cannot be observed
on Linux; a Mac test on Chinese and English is required.

### S2 — refresh queue coalescing

**Files:** `AirBattery/Supports/AirBatteryApp.swift`,
`AirBattery/ViewModel/ContentView.swift`

`refreshWidgetData` now keeps lock-protected active/pending state. At most one
pass runs and at most one more is queued; a request arriving during a pass
OR-merges `includeIDevices`, `refreshBluetooth` and `reloadWidgets`, and its
completion is appended to the pending pass. A user-initiated Reload therefore
cannot lose its reload. The 24-second `widgetDataTimer` now passes
`includeIDevices: false` because the 5-second `dockTimer` already drives iDevice
scans.

Not done: no long-running stress test of the backlog; static reasoning only.

### S3 — safe parsing of truncated iDevice output

**Files:** `AirBattery/BatteryInfo/IDeviceBattery.swift`

Removed the `Int(level)!`, `Bool(charging)!`, `Int(watchLevel)!` and
`Bool(watchCharging)!` traps. Level/charging strings are trimmed of whitespace
and newlines and parsed with optional binding; the device (or watch) is skipped
if the output is incomplete. Also removed the `first!` on the charging field.

Not done: `process()` still does not expose whether the timeout fired; with the
safe parsing that is not required for crash safety.

### S4 — `system_profiler` timeouts

**Files:** `AirBattery/BatteryInfo/MagicBattery.swift`,
`AirBattery/Supports/AirBatteryApp.swift`

Both `system_profiler SPBluetoothDataType -json` calls (the refresh helper and
the launch-time cache warm-up) now use `timeout: 30`, so the serial connect and
widget-refresh queues cannot wait forever after a `bluetoothd` restart.

Not done: the launch-time call still runs on the main thread (pre-existing); it
is now bounded but can still block launch for up to 30 s in a pathological case.

### S5 — one periodic widget reload source

**Files:** `AirBattery/Supports/AirBatteryApp.swift`

The new app-level timer now passes `reloadWidgets: false`; it only rewrites the
JSON. The existing `widgetViewTimer` in `ContentView.swift` remains the single
periodic `reloadAllTimelines()` source and still honors `widgetInterval == -1`.
`widgetRefreshTimer?.tolerance = 10` lets the OS batch wakeups.

### S6 — remaining off-main `IOBluetoothDevice` use

**Files:** `AirBattery/BatteryInfo/MagicBattery.swift`,
`AirBattery/BatteryInfo/BTDBattery.swift`

`MagicBattery.getIOBTBattery()` now enumerates `IOBluetoothDevice.pairedDevices()`
and reads name/address/isConnected/isAppleDevice/batteryPercentSingle on the
main thread (`Thread.isMainThread` check, otherwise `DispatchQueue.main.sync`),
returning a private value-type `PairedDeviceSnapshot`. `BTDBattery.getConnected()`
does the same with a private `ConnectedDeviceSnapshot` for name/address. No
`IOBluetoothDevice` object escapes those closures.

Not done: `BTTool.connect/disconnect` still enumerate `IOBluetoothDevice`
directly from Multipeer callbacks. It was outside the review's S6 list and the
requested scope; it should be converted to the same snapshot pattern in a later
change if those paths are used.

### N1 — atomic last-update touch

**Files:** `AirBattery/BatteryInfo/AirBatteryModel.swift`,
`AirBattery/BatteryInfo/BTDBattery.swift`

Added `AirBatteryModel.touchDevice(name:)`, which updates `lastUpdate` in place
under `devicesLock`. `BTDBattery.scanDevices` uses it instead of
`getByName` + mutate + `updateDevice`, avoiding a stale read-modify-write.

### N2 — redundant macOS 14 selector branch

**File:** `AirBattery/ViewModel/ContentView.swift`

`openSettingPanel()` no longer calls the `showSettingsWindow:` selector on
macOS 14+ (where it is a documented no-op). macOS 13 still gets the selector
fallback and macOS 11/12 gets `showPreferencesWindow:`.

### N3 — menu search priority

**File:** `AirBattery/ViewModel/ContentView.swift`

`performSettingsMenuItem()` now does two full passes: first exact
`showSettingsWindow:` / `showPreferencesWindow:` selector names, then the
Cmd-, shortcut heuristic. The shortcut can no longer take priority over a real
Settings action.

### N4 — `writedata` URL semantics

**File:** `AirBattery/Supports/AirBatteryApp.swift`

The `airbattery://writedata` handler now passes `refreshBluetooth: false`, so it
only rewrites the current data instead of running a full Bluetooth scan.

### N5 — `writeLock` comment

**File:** `AirBattery/BatteryInfo/AirBatteryModel.swift`

The comment now states that `writeLock` serializes writers only inside this
process; `.atomic` is what protects the widget extension's reads across
processes.

### N6 — timeout documentation/code consistency

**File:** `AirBattery/BatteryInfo/IDeviceBattery.swift`

Timeouts are now `-n` (Wi-Fi/network) 30 s, `-l` (USB/local) 20 s,
`wificonnection` 20 s, and `ideviceinfo`/`comptest` 30 s. The documentation now
matches those meanings. `getPencil`'s detached thread remains pre-existing and
was not coalesced in this round.

### N7 — `scanDevicesNow()` flag handling

**File:** `AirBattery/BatteryInfo/IDeviceBattery.swift`

`scanDevicesNow()` now sets `isScanning` when it starts its own pass and clears
it at the end. If a scan is already in flight, it waits on `scanQueue.sync {}`
for that pass instead of enqueueing a duplicate full scan. It must still never
be called from inside `scanQueue` (it is only called from `widgetRefreshQueue`).

### N8 — documentation corrections

**File:** `CHANGES-dsh.md`

Corrected the round-1 text: round 1 is committed as `21655a3`; `widgetDataTimer`
fires every 24 seconds (not 24 minutes); timeouts are 20 s/30 s with the correct
`-n`/`-l` meanings; the Dock menu and `applicationShouldHandleReopen` already
called `openSettingPanel()` upstream. Added this Round 2 section and updated
the verification checklist.

## Not verified (cannot build on Linux)

This machine has no Xcode, macOS SDK, Swift toolchain, or macOS runtime. Nothing
below has been compiled or run. A reviewer on macOS must check:

### Compile/API availability

- `@Environment(\.openSettings)` and `OpenSettingsButton` are guarded with
  `@available(macOS 14.0, *)`; verify the project's SDK/Swift version accepts the
  availability annotation and that the `@ViewBuilder` closure initializer
  compiles.
- `NSApp.activate()` is used only inside `if #available(macOS 14.0, *)`;
  `activate(ignoringOtherApps:)` is the fallback. Confirm no deprecation error
  (rather than warning) in the project's Swift settings.
- `NSWindow.orderFrontRegardless()`, `NSWindow.willCloseNotification`,
  `NSApp.setActivationPolicy`, `NSWindow.canBecomeMain`, and
  `NotificationCenter.addObserver(forName:object:queue:using:)` availability.
- `import Darwin` and `kill(pid, SIGKILL)` in `Supports.swift`: confirm the
  Darwin symbol is visible in the app/widget target build settings and that the
  `Int32` process identifier/SIGKILL types match.
- The weak capture `[weak task]` in the `DispatchWorkItem` and the
  `DispatchWorkItem` cancellation logic compile under the project's Swift
  version.
- `AirBatteryModel.Devices`, `SPBluetoothDataModel.data`, `InternalBattery.status`
  and `BTDBattery.allDevices` changed from stored properties to computed
  properties. Confirm no target (especially the widget extension) relies on
  key paths, `@objc`/KVO, or stored-property initialization of these names.
- No `.pbxproj` change was made. Confirm all edited files are already in the
  correct app/widget target memberships.
- `WidgetRefreshRequest` and the coalescing state are `private` to
  `AirBatteryApp.swift` (app target only). Confirm the `[() -> Void]` completion
  array and the `NSLock`-protected globals compile under Swift 5.
- The `if #available(macOS 13, *) { if #unavailable(macOS 14) { … } }` construct
  in `openSettingPanel()` compiles with the project's Swift version (it already
  uses `#unavailable` elsewhere).
- `NSLocalizedString("AirBattery Settings", comment: "")` is resolved against the
  app bundle; the key exists in the localized `Localizable.strings` files.
- `Timer.tolerance = 10` is available on the macOS 11 deployment target; confirm
  the timer property is non-nil when set (it is created just above).
- `NSWindow.identifier?.rawValue` may be nil or use a different SwiftUI string on
  some macOS versions; the localized/English title fallbacks are intentional.

### #175 behaviour to test manually

- macOS 26 (and macOS 14/15): click the popover gear. Settings must appear in
  front, become key, and the popover must close. Test both when no Settings
  window exists and when it is already open.
- Set the system language to Chinese and open Settings a **second** time. The
  window must stay tracked (identifier/localized-title lookup), must not be
  demoted after the 2-second grace period, and the Dock icon must remain while
  it is open and disappear only after closing. Repeat with English.
- Test the application/Dock menu “Settings...” item and
  `applicationShouldHandleReopen` in menu-bar (`LSUIElement`) mode. These already
  called `openSettingPanel()` upstream; only the helper changed.
- Verify the two-pass menu search finds the SwiftUI Settings item on each macOS
  version. On macOS 14+ there is no `sendAction` fallback (the selector is a
  no-op); `openSettings()` and the menu-item search are the remaining paths.
- Verify the temporary `.regular` activation policy does not leave a Dock icon
  after closing Settings in `sbar`/`none` mode. The restore relies on either the
  `WindowAccessor` close callback or the `willCloseNotification` observer; test
  closing with the red button, Cmd-W, and while another app is active.
- Verify activation does not disturb the menu-bar item or the `showOn`
  dock/both/None settings.

### #215 / #206 / #124 behaviour to test manually

- Sleep/wake with several Bluetooth devices reconnecting. Confirm no crash and
  no memory-corruption reports. The crash is a race, so a single successful run
  does not prove it is gone; repeat the wake cycle.
- Check Console/Activity Monitor for deadlocks or long main-thread stalls. The
  device/data/status locks are only held around array/string/struct snapshots,
  never around `system_profiler`, IOBluetooth calls, or `UserDefaults`. The
  separate `writeLock` is held only for the atomic `data.json` write and does
  not call back into model code. Verify that this remains true if new call sites
  are added later.
- Confirm `IDeviceBattery.scanDevicesNow()` is never called from inside
  `scanQueue` (currently it is only called from `widgetRefreshQueue`); doing so
  would deadlock the serial queue.
- Confirm no `DispatchQueue.main.sync` in `MagicBattery.pairedDeviceSnapshots()`
  or `BTDBattery.connectedDeviceSnapshots()` runs while the main thread is
  synchronously waiting on those background queues. The current call sites are
  detached scans, `deviceConnectQueue`, and `widgetRefreshQueue`; main itself
  calls these helpers only with `Thread.isMainThread == true` (direct read).
  Watch launch-time `system_profiler` (up to 30 s on main) — it can delay but
  should not deadlock a detached scan.
- Check that the refresh coalescing state never leaves `widgetRefreshActive`
  stuck true (e.g. kill a very long iDevice scan) and that a Reload request
  arriving mid-pass still triggers a later pass with `reloadWidgets == true`.
- Verify the `process` timeout path still terminates hung commands and that
  `kill(pid, SIGKILL)` is permitted for the app (the app is not sandboxed).
- Confirm the app-level Timer is invalidated on quit and does not retain the
  AppDelegate/window graph indefinitely.

### #104 behaviour to test manually

- Click “Reload All Widgets” with an iPad that has gone offline. It should
  disappear from the widget after the configured removal window, not only after
  relaunching the app.
- Keep the popover closed for several minutes and verify iDevice/Bluetooth
  values still update in the widget.
- Verify the app-level `60 * updateInterval` timer does not cause excessive
  `system_profiler`/libimobiledevice activity, and that “System Default” widget
  refresh still behaves as expected.
- Confirm the app-level timer only writes JSON (`reloadWidgets: false`) and that
  the existing `widgetViewTimer` is the only periodic timeline reload. Watch
  Activity Monitor for doubled reloads or throttling.
- Verify the 24-second `widgetDataTimer` no longer runs an iDevice scan
  (`includeIDevices: false`) and that the 5-second `dockTimer` still keeps
  iDevice data current while the view is alive.
- Feed a truncated `ideviceinfo`/`comptest` output (or kill it at the timeout)
  and confirm a device is skipped instead of crashing.
- Verify the atomic `data.json` write is visible to the widget extension in the
  app-group container and that the widget does not briefly show an empty list.
- Test the `airbattery://reloadwingets` URL and the AppleScript
  `reload all widgets` command.

### Widget / iDevice assumptions

- The widget extension reads `data.json` through the existing
  `com.lihaoyun6.AirBattery.widget` container path; this was not changed.
- iPhones/iPads still require the existing USB/Wi-Fi trust pairing; the serial
  queue does not add or remove any libimobiledevice capability.
- Widget ring sizes/offsets, colors, charging bolt, and percentage placement
  were not visually tested. Only static code review was possible.

## Accessory power notifications

Mac-local mouse, keyboard, and trackpad batteries can refresh from powerd's
accessory channel (`com.apple.system.accpowersources.*`) without subscribing to
the public main-battery notifications. iPhone, iPad, and Watch polling is
unchanged. Apple Watch is still read through iPhone lockdown (`comptest`);
the Watch accessory category is ignored. Details and the Mac checklist are in
`docs/mac-accessory-power.md`. `scripts/check-accessory-power.sh` is a Linux-side
static check only.

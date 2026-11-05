//
//  AccessoryPowerMonitor.swift
//  AirBattery
//
//  Listens for Mac-local accessory power changes (Magic Mouse, Magic Keyboard,
//  Magic Trackpad, and the same categories from other transports) and refreshes
//  only those devices.
//
//  Public IOPowerSources run-loop sources and the main-battery notify names
//  are intentionally absent. They report the Mac's own battery and UPS only
//  (IOPSCopyPowerSourcesInfo is internal+UPS). See docs/mac-accessory-power.md.
//
//  Accessory coverage is the separate powerd channel used by `pmset accpslog`,
//  declared in IOPowerSourcesPrivate.h. The three names are listed in
//  AccessoryPowerMonitor.notifyNames. Subscription uses public notify(3).
//  The private C run-loop wrappers are not linked. The accessory snapshot
//  symbol is resolved with dlsym so a missing export does not prevent launch;
//  the existing HID scan remains the fallback.
//
//  Apple Watch stays on the iPhone lockdown / comptest path. Category "Watch"
//  is ignored. This file does not call idevice, comptest, system_profiler,
//  or CoreBluetooth.
//

import Foundation
import IOKit.ps
import Darwin
import WidgetKit

/// Identifiers observed in the Apple HID registry during one refresh.
/// The IOPS accessory pass skips these so BatteryStatusFlags parsing wins.
final class HIDIdentityBag {
    var ids = Set<String>()
    var names = Set<String>()
}

enum AccessoryPowerRules {
    static let allowedCategories: Set<String> = ["Mouse", "Keyboard", "Trackpad"]
    /// Devices whose battery is owned by another reader. Never overwrite them
    /// from a Mac accessory power event. Watch is read through the paired
    /// iPhone; IOPS on the Mac is not that path.
    static let protectedDeviceTypes: Set<String> = ["Watch", "iPhone", "iPad", "iPod", "Pencil", "ApplePencil"]

    static func normalizeID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    /// Mouse / Keyboard / Trackpad only. Explicit Watch is refused even when
    /// the name does not contain "watch". Empty or Unknown category may still
    /// match a Bluetooth/USB/BLE device whose name says mouse, keyboard, or
    /// trackpad. Every other category (headphones, game controllers, pencil,
    /// iPhone) is left to its existing reader.
    static func resolvedCategory(category: String, name: String, transport: String) -> String? {
        if category == "Watch" { return nil }
        if allowedCategories.contains(category) { return category }
        if !category.isEmpty && category != "Unknown" { return nil }
        let transports: Set<String> = ["Bluetooth", "Bluetooth LE", "USB"]
        guard transports.contains(transport) else { return nil }
        let lower = name.lowercased()
        if lower.contains("watch") { return nil }
        if lower.contains("mouse") { return "Mouse" }
        if lower.contains("trackpad") { return "Trackpad" }
        if lower.contains("keyboard") { return "Keyboard" }
        return nil
    }

    static func deviceType(for category: String) -> String {
        category == "Mouse" ? "MMouse" : category
    }

    /// Current Capacity is a percent when Max Capacity is missing or 100.
    /// Otherwise it is scaled. Values outside 0...100 are ignored.
    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    static func percent(current: Int, max: Int) -> Int? {
        let value: Int
        if max > 0 && max != 100 {
            value = Int((Double(current) / Double(max) * 100.0).rounded())
        } else {
            value = current
        }
        return (0...100).contains(value) ? value : nil
    }
}

final class AccessoryPowerMonitor {
    static let shared = AccessoryPowerMonitor()

    /// powerd posts these when an accessory power source changes.
    /// Main-battery names are intentionally not in this list.
    static let notifyNames = [
        "com.apple.system.accpowersources.timeremaining",
        "com.apple.system.accpowersources.attach",
        "com.apple.system.accpowersources.source"
    ]

    /// IOPowerSourcesPrivate.h: 0 all, 1 internal, 2 UPS, 3 internal+UPS, 4 accessories.
    private let accessorySourceType: Int32 = 4

    private let queue = DispatchQueue(label: "com.lihaoyun6.AirBattery.acc-power")
    private let lock = NSLock()
    private var tokens: [Int32] = []
    private var started = false
    private var debounceItem: DispatchWorkItem?
    private var burstStart: Date?
    private var reloadPending = false
    private var lastReload = Date.distantPast
    private var loggedCopyFailure = false

    private init() {}

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        var registered: [Int32] = []
        for name in Self.notifyNames {
            var token: Int32 = 0
            let status = name.withCString { cString -> UInt32 in
                notify_register_dispatch(cString, &token, queue) { [weak self] _ in
                    self?.notePowerEvent()
                }
            }
            if status == 0 {
                registered.append(token)
            } else {
                NSLog("AirBattery accessory notify \(name) failed status \(status)")
            }
        }

        lock.lock()
        tokens = registered
        if tokens.isEmpty {
            started = false
            lock.unlock()
            NSLog("AirBattery accessory power notifications unavailable; keeping existing scans")
            return
        }
        lock.unlock()
        NSLog("AirBattery listening for \(registered.count) accessory power notifications")
    }

    func stop() {
        lock.lock()
        let pending = tokens
        tokens.removeAll()
        started = false
        lock.unlock()
        for token in pending {
            _ = notify_cancel(token)
        }
        queue.async { [weak self] in
            self?.debounceItem?.cancel()
            self?.debounceItem = nil
            self?.burstStart = nil
        }
    }

    /// Coalesce a burst. An isolated event waits 2 s. A continuous stream
    /// (time-remaining while a device is charging) still runs within 5 s.
    /// Always hop onto `queue`: notify may deliver the block inline.
    private func notePowerEvent() {
        queue.async { [weak self] in
            self?.notePowerEventOnQueue()
        }
    }

    private func notePowerEventOnQueue() {
        let now = Date()
        if burstStart == nil { burstStart = now }
        debounceItem?.cancel()
        let elapsed = now.timeIntervalSince(burstStart ?? now)
        let delay: TimeInterval = elapsed >= 5 ? 0 : 2
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.burstStart = nil
            self.debounceItem = nil
            self.refreshLocalAccessories()
        }
        debounceItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func readBTDeviceEnabled() -> Bool {
        if ud.object(forKey: "readBTDevice") == nil { return true }
        return ud.bool(forKey: "readBTDevice")
    }

    private func refreshLocalAccessories() {
        lock.lock()
        let active = started
        lock.unlock()
        guard active else { return }
        guard readBTDeviceEnabled() else { return }
        let bag = HIDIdentityBag()
        var changed = false
        if MagicBattery.shared.getMagicBattery(onlyIfChanged: true, bag: bag) { changed = true }
        if MagicBattery.shared.getOldMagicKeyboard(onlyIfChanged: true, bag: bag) { changed = true }
        if MagicBattery.shared.getOldMagicTrackpad(onlyIfChanged: true, bag: bag) { changed = true }
        if MagicBattery.shared.getOldMagicMouse(onlyIfChanged: true, bag: bag) { changed = true }
        if applyAccessorySources(excluding: bag) { changed = true }
        guard changed else { return }
        NSLog("AirBatteryTiming accessory power state changed")
        AirBatteryModel.writeData()
        scheduleWidgetReload()
    }

    /// Devices already visited in the HID registry keep that parse (including
    /// BatteryStatusFlags). This pass only fills Mouse/Keyboard/Trackpad rows
    /// that the registry walk did not see.
    private func applyAccessorySources(excluding bag: HIDIdentityBag) -> Bool {
        guard let sources = copyAccessoryPowerDictionaries() else { return false }
        let parent = ud.string(forKey: "deviceName") ?? "Mac"
        let now = Date().timeIntervalSince1970
        var changed = false
        for info in sources {
            let type = info[kIOPSTypeKey] as? String ?? ""
            if type == kIOPSInternalBatteryType || type == kIOPSUPSType { continue }
            let transport = info[kIOPSTransportTypeKey] as? String ?? ""
            if transport == kIOPSInternalType { continue }
            if AccessoryPowerRules.boolValue(info[kIOPSIsPresentKey]) == false { continue }
            let name = (info[kIOPSNameKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let category = info["Accessory Category"] as? String ?? ""
            guard let resolved = AccessoryPowerRules.resolvedCategory(category: category, name: name, transport: transport) else { continue }
            guard let current = AccessoryPowerRules.intValue(info[kIOPSCurrentCapacityKey]) else { continue }
            let maxCapacity = AccessoryPowerRules.intValue(info[kIOPSMaxCapacityKey]) ?? 0
            guard let percent = AccessoryPowerRules.percent(current: current, max: maxCapacity) else { continue }
            let charging = (AccessoryPowerRules.boolValue(info[kIOPSIsChargingKey]) ?? false) ? 1 : 0
            let rawID = info["Accessory Identifier"] as? String ?? ""
            let normID = AccessoryPowerRules.normalizeID(rawID)
            if !normID.isEmpty && bag.ids.contains(normID) { continue }
            if !name.isEmpty && bag.names.contains(name) { continue }

            let stored = AirBatteryModel.Devices
            let existing = stored.first { device in
                if !normID.isEmpty && AccessoryPowerRules.normalizeID(device.deviceID) == normID { return true }
                if !name.isEmpty && device.deviceName == name { return true }
                return false
            }
            if let existing = existing {
                if AccessoryPowerRules.protectedDeviceTypes.contains(existing.deviceType) { continue }
                if existing.batteryLevel == percent && existing.isCharging == charging { continue }
                var updated = existing
                updated.batteryLevel = percent
                updated.isCharging = charging
                updated.lastUpdate = now
                AirBatteryModel.updateDevice(updated)
                changed = true
                continue
            }
            guard !name.isEmpty else { continue }
            let deviceID = normID.isEmpty ? name : normID
            AirBatteryModel.updateDevice(Device(
                deviceID: deviceID,
                deviceType: AccessoryPowerRules.deviceType(for: resolved),
                deviceName: name,
                batteryLevel: percent,
                isCharging: charging,
                parentName: parent,
                lastUpdate: now
            ))
            changed = true
        }
        return changed
    }

    /// nil means the private export is missing. An empty array means powerd
    /// published no accessory sources; the HID walk is still the fallback.
    private func copyAccessoryPowerDictionaries() -> [[String: Any]]? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "IOPSCopyPowerSourcesByType") else {
            if !loggedCopyFailure {
                loggedCopyFailure = true
                NSLog("AirBattery IOPSCopyPowerSourcesByType is unavailable; HID fallback only")
            }
            return nil
        }
        typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        let copy = unsafeBitCast(symbol, to: CopyFn.self)
        guard let unmanaged = copy(accessorySourceType) else { return [] }
        let blob = unmanaged.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return [] }
        // Same cast the internal-battery reader already uses.
        let sources = listRef.takeRetainedValue() as Array
        var dictionaries: [[String: Any]] = []
        for ps in sources {
            let description = IOPSGetPowerSourceDescription(blob, ps).takeUnretainedValue()
            guard let dictionary = description as? [String: Any] else { continue }
            dictionaries.append(dictionary)
        }
        return dictionaries
    }

    /// State-change reload only. The 60 s widgetViewTimer is unchanged.
    /// At most one reload per 15 s, matching the existing charging-reload budget
    /// that is defined but not installed.
    private func scheduleWidgetReload() {
        DispatchQueue.main.async {
            if self.reloadPending { return }
            self.reloadPending = true
            let wait = max(1.5, 15 - Date().timeIntervalSince(self.lastReload))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.reloadPending = false
                self.lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
                refeshPinnedBar()
                NSLog("AirBatteryTiming accessory widget reload")
            }
        }
    }
}

@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

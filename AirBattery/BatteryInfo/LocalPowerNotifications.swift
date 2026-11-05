//
//  LocalPowerNotifications.swift
//  AirBattery
//
//  Public notifications for this Mac's battery and for a connected mouse.
//  An interest callback is only a hint to re-read the existing HID properties.
//  The message type is not given a private meaning.

import Foundation
import IOKit
import IOKit.ps
import WidgetKit

private let mouseQuietSeconds: TimeInterval = 0.4
private let macSettleSeconds: TimeInterval = 0.4
private let macMinimumGap: TimeInterval = 2
private let widgetReloadGap: TimeInterval = 15

private var localPowerReloadPending = false
private var lastLocalPowerReload = Date.distantPast

// Writes the widget JSON from memory and reloads timelines. It does not scan
// iPhone, iPad, Watch, or BLE. Bursts collapse into one reload, and reloads
// are at least 15 seconds apart. widgetInterval == -1 still skips the reload.
func scheduleLocalPowerWidgetReload() {
    let schedule = {
        if localPowerReloadPending { return }
        localPowerReloadPending = true
        let wait = max(1.0, widgetReloadGap - Date().timeIntervalSince(lastLocalPowerReload))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            localPowerReloadPending = false
            lastLocalPowerReload = Date()
            DispatchQueue.global(qos: .utility).async {
                AirBatteryModel.writeData()
                DispatchQueue.main.async {
                    if widgetInterval != -1 {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
        }
    }
    if Thread.isMainThread {
        schedule()
    } else {
        DispatchQueue.main.async(execute: schedule)
    }
}

private func macPowerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    MacPowerNotifications.shared.scheduleRead()
}

// Create returns +1. GetRunLoopSource does not. Accept either an optional or a
// plain Unmanaged so a nil source does not get force-unwrapped.
private func retainedRunLoopSource(_ source: Unmanaged<CFRunLoopSource>?) -> CFRunLoopSource? {
    source?.takeRetainedValue()
}

private func unretainedRunLoopSource(_ source: Unmanaged<CFRunLoopSource>?) -> CFRunLoopSource? {
    source?.takeUnretainedValue()
}

private func mouseAppeared(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    MousePowerInterest.shared.drain(iterator, terminated: false)
}

private func mouseDisappeared(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    MousePowerInterest.shared.drain(iterator, terminated: true)
}

private func mouseInterest(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?) {
    _ = refcon
    _ = messageType
    _ = messageArgument
    guard IOObjectRetain(service) == KERN_SUCCESS else { return }
    var id: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 else {
        IOObjectRelease(service)
        return
    }
    let retained = service
    let entry = id
    DispatchQueue.main.async {
        MousePowerInterest.shared.scheduleRead(id: entry, service: retained)
    }
}

final class MacPowerNotifications {
    static let shared = MacPowerNotifications()

    private var started = false
    private var source: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    private var pendingRead: DispatchWorkItem?
    private var readScheduled = false
    private var lastReadAt = Date.distantPast

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        // IOPSNotificationCreateRunLoopSource delivers percent remaining, time
        // remaining, and AC/battery/UPS changes. IOPSCreateLimitedPowerNotification
        // only delivers the AC switch, so it is not used here.
        if let source = retainedRunLoopSource(IOPSNotificationCreateRunLoopSource(macPowerSourceChanged, nil)) {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            print("⚠️ IOPSNotificationCreateRunLoopSource returned nil")
        }
        if #available(macOS 12.0, *) {
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { _ in
                MacPowerNotifications.shared.scheduleRead()
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        started = false
        pendingRead?.cancel()
        pendingRead = nil
        readScheduled = false
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
            self.lowPowerObserver = nil
        }
    }

    func scheduleRead() {
        let schedule = {
            guard self.started else { return }
            if self.readScheduled { return }
            self.readScheduled = true
            let elapsed = Date().timeIntervalSince(self.lastReadAt)
            let delay = max(macSettleSeconds, macMinimumGap - elapsed)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.readScheduled = false
                guard self.started else { return }
                self.lastReadAt = Date()
                self.publishIfChanged()
            }
            self.pendingRead = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func publishIfChanged() {
        let next = getPowerState()
        let previous = InternalBattery.status
        let same = previous.hasBattery == next.hasBattery
            && previous.isCharging == next.isCharging
            && previous.isCharged == next.isCharged
            && previous.acPowered == next.acPowered
            && previous.batteryLevel == next.batteryLevel
            && previous.lowPower == next.lowPower
            && previous.timeLeft == next.timeLeft
        if same { return }
        print("ℹ️ Mac power \(next.batteryLevel)% charging=\(next.isCharging) ac=\(next.acPowered) lowPower=\(next.lowPower) time=\(next.timeLeft)")
        InternalBattery.status = next
        let reloadWidget = previous.hasBattery != next.hasBattery
            || previous.isCharging != next.isCharging
            || previous.isCharged != next.isCharged
            || previous.acPowered != next.acPowered
            || previous.batteryLevel != next.batteryLevel
            || previous.lowPower != next.lowPower
        if reloadWidget { scheduleLocalPowerWidgetReload() }
    }
}

final class MousePowerInterest {
    static let shared = MousePowerInterest()

    private struct PendingRead {
        var service: io_object_t
        var work: DispatchWorkItem
    }

    private let mainPort: mach_port_t = {
        if #available(macOS 12.0, *) { return kIOMainPortDefault }
        return kIOMasterPortDefault
    }()

    private var started = false
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var interests: [UInt64: io_object_t] = [:]
    private var pending: [UInt64: PendingRead] = [:]

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        guard let port = IONotificationPortCreate(mainPort) else {
            print("⚠️ IONotificationPortCreate failed")
            return
        }
        self.port = port
        guard let source = unretainedRunLoopSource(IONotificationPortGetRunLoopSource(port)) else {
            IONotificationPortDestroy(port)
            self.port = nil
            print("⚠️ IONotificationPortGetRunLoopSource returned nil")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        started = true
        addMatching("BNBMouseDevice")
        addMatching("AppleDeviceManagementHIDEventService")
        print("ℹ️ Mouse power interest listening")
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started || port != nil else { return }
        started = false
        if let port {
            if let source = unretainedRunLoopSource(IONotificationPortGetRunLoopSource(port)) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
            self.port = nil
        }
        for item in pending.values {
            item.work.cancel()
            IOObjectRelease(item.service)
        }
        pending.removeAll()
        for note in interests.values {
            IOObjectRelease(note)
        }
        interests.removeAll()
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()
    }

    // Wake can drop events while the machine is asleep. Re-read only mice that
    // already have an interest registration.
    func rereadArmed() {
        let hop = {
            guard self.started else { return }
            let ids = Array(self.interests.keys)
            for id in ids {
                let matching = IORegistryEntryIDMatching(id) as CFDictionary
                var iterator = io_iterator_t()
                let kr = IOServiceGetMatchingServices(self.mainPort, matching, &iterator)
                if kr != KERN_SUCCESS {
                    if iterator != 0 { IOObjectRelease(iterator) }
                    continue
                }
                var service = IOIteratorNext(iterator)
                while service != 0 {
                    if IOObjectRetain(service) == KERN_SUCCESS {
                        self.scheduleRead(id: id, service: service)
                    }
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                IOObjectRelease(iterator)
            }
        }
        if Thread.isMainThread {
            hop()
        } else {
            DispatchQueue.main.async(execute: hop)
        }
    }

    fileprivate func drain(_ iterator: io_iterator_t, terminated: Bool) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if terminated {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 {
                    let entry = id
                    DispatchQueue.main.async {
                        MousePowerInterest.shared.releaseInterest(entry)
                    }
                }
            } else if isMouse(service) {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 {
                    arm(service, id: id)
                    if IOObjectRetain(service) == KERN_SUCCESS {
                        let entry = id
                        let retained = service
                        DispatchQueue.main.async {
                            MousePowerInterest.shared.scheduleRead(id: entry, service: retained)
                        }
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    fileprivate func scheduleRead(id: UInt64, service: io_service_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else {
            IOObjectRelease(service)
            return
        }
        if let old = pending.removeValue(forKey: id) {
            old.work.cancel()
            IOObjectRelease(old.service)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.performRead(id: id)
        }
        pending[id] = PendingRead(service: service, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + mouseQuietSeconds, execute: work)
    }

    fileprivate func releaseInterest(_ id: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let note = interests.removeValue(forKey: id) {
            IOObjectRelease(note)
        }
        if let item = pending.removeValue(forKey: id) {
            item.work.cancel()
            IOObjectRelease(item.service)
        }
    }

    private func performRead(id: UInt64) {
        guard let item = pending.removeValue(forKey: id) else { return }
        defer { IOObjectRelease(item.service) }
        guard started else { return }
        MagicBattery.shared.readMagicBattery(object: item.service, publishIfChanged: true)
    }

    private func arm(_ service: io_service_t, id: UInt64) {
        guard let port, started else { return }
        if interests[id] != nil { return }
        if interests.count >= 32 { return }
        var note: io_object_t = 0
        let kr = kIOGeneralInterest.withCString { name in
            IOServiceAddInterestNotification(port, service, name, mouseInterest, nil, &note)
        }
        guard kr == KERN_SUCCESS, note != 0 else { return }
        interests[id] = note
    }

    private func addMatching(_ className: String) {
        guard let port else { return }
        var appeared = io_iterator_t()
        let matching = IOServiceMatching(className) as CFDictionary
        let kr = kIOFirstMatchNotification.withCString { name in
            IOServiceAddMatchingNotification(port, name, matching, mouseAppeared, nil, &appeared)
        }
        if kr == KERN_SUCCESS {
            iterators.append(appeared)
            drain(appeared, terminated: false)
        } else if appeared != 0 {
            IOObjectRelease(appeared)
        }

        var gone = io_iterator_t()
        let matchingGone = IOServiceMatching(className) as CFDictionary
        let krGone = kIOTerminatedNotification.withCString { name in
            IOServiceAddMatchingNotification(port, name, matchingGone, mouseDisappeared, nil, &gone)
        }
        if krGone == KERN_SUCCESS {
            iterators.append(gone)
            drain(gone, terminated: true)
        } else if gone != 0 {
            IOObjectRelease(gone)
        }
    }

    private func isMouse(_ service: io_service_t) -> Bool {
        let className = registryClass(service)
        if className == "BNBMouseDevice" || className.contains("Mouse") { return true }
        let product = stringProperty(service, "Product")
        if product.range(of: "mouse", options: .caseInsensitive) != nil { return true }
        if intProperty(service, "PrimaryUsagePage") == 0x01 && intProperty(service, "PrimaryUsage") == 0x02 {
            return true
        }
        return false
    }

    private func registryClass(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String {
        if let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) {
            if let text = raw.takeRetainedValue() as? String { return text }
        }
        return ""
    }

    private func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        if let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) {
            let value = raw.takeRetainedValue()
            if let number = value as? Int { return number }
            if let number = value as? NSNumber { return number.intValue }
        }
        return nil
    }
}

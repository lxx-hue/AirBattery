//
//  AirBatteryModel.swift
//  AirBattery
//
//  Created by apple on 2024/2/6.
//
import SwiftUI
import Foundation

class IDeviceBattery {
    static var shared: IDeviceBattery = IDeviceBattery()
    
    private let scanQueue = DispatchQueue(label: "com.lihaoyun6.AirBattery.idevice-scan")
    private let stateLock = NSLock()
    private var isScanning = false
    private var scanQueued = false

    //var scanTimer: Timer?
    @AppStorage("readPencil") var readPencil = false
    @AppStorage("readIDevice") var readIDevice = true
    @AppStorage("updateInterval") var updateInterval = 1
    
    func startScan() {
        //let interval = TimeInterval(5.0)
        //scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scanDevices), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning iDevice devices...")
        scanDevices()
    }
    
    @objc func scanDevices() {
        guard readIDevice else { return }
        // Never run two libimobiledevice sessions at once. Coalesce callers
        // (dock timer + app-level widget timer + the Reload button) instead of
        // spawning a detached thread per request.
        stateLock.lock()
        if isScanning {
            scanQueued = true
            stateLock.unlock()
            return
        }
        isScanning = true
        // Enqueue while still holding the lock so scanDevicesNow() can rely on
        // "isScanning == true" meaning a pass is actually queued or running.
        scanQueue.async {
            self.getIDeviceBattery()
            self.stateLock.lock()
            self.isScanning = false
            let again = self.scanQueued
            self.scanQueued = false
            self.stateLock.unlock()
            if again { self.scanDevices() }
        }
        stateLock.unlock()
    }

    // Synchronous variant used by the widget refresh path, which must finish
    // the iDevice scan before writing the shared JSON. Runs on `scanQueue`, so
    // it also serializes with any in-flight scanDevices() call.
    func scanDevicesNow() {
        stateLock.lock()
        let alreadyScanning = isScanning
        if !alreadyScanning { isScanning = true }
        stateLock.unlock()

        if alreadyScanning {
            // Wait for the in-flight pass; it is already refreshing the same
            // data, so do not queue a duplicate full scan.
            scanQueue.sync {}
            return
        }

        scanQueue.sync {
            if self.readIDevice { self.getIDeviceBattery() }
            self.stateLock.lock()
            self.isScanning = false
            let again = self.scanQueued
            self.scanQueued = false
            self.stateLock.unlock()
            if again { self.scanDevices() }
        }
    }
    
    func getPencil(d: Device, type: String = "") {
        if d.deviceType == "iPad" && readPencil {
            Thread.detachNewThread {
                if let result = process(path: "/bin/bash", arguments: ["\(Bundle.main.resourcePath!)/logReader.sh", "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevicesyslog", type, d.deviceID], timeout: 11 * self.updateInterval) {
                    if let json = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: []) as? [String: Any] {
                        if let level = json["level"] as? Int, let model = json["model"] as? String, let vendor = json["vendor"] as? String {
                            let status = (json["status"] as? Int) ?? 0
                            print("ℹ️ Pencil of \(d.deviceName): \(result)")
                            AirBatteryModel.updateDevice(Device(deviceID: "Pencil_"+d.deviceID, deviceType: vendor == "Apple" ? "ApplePencil" : "Pencil", deviceName: vendor == "Apple" ? "Apple Pencil".local : "Pencil".local, deviceModel: model, batteryLevel: level, isCharging: status, parentName: d.deviceName, lastUpdate: Date().timeIntervalSince1970))
                        }
                    }
                }
            }
        }
    }
    
    func getIDeviceBattery() {
        var networkIDs = Set<String>()
        var usbIDs = Set<String>()

        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-n"], timeout: 30) {
            for id in result.components(separatedBy: .newlines) where !id.isEmpty {
                networkIDs.insert(id)
                if let d = AirBatteryModel.getByID(id) {
                    let age = Double(Date().timeIntervalSince1970) - d.lastUpdate
                    if age > Double(60 * updateInterval) { writeBatteryInfo(id, "-n") }
                    getPencil(d: d, type: "-n")
                } else {
                    writeBatteryInfo(id, "-n")
                }
            }
        }
        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-l"], timeout: 20) {
            for id in result.components(separatedBy: .newlines) where !id.isEmpty {
                usbIDs.insert(id)
                if let d = AirBatteryModel.getByID(id) {
                    if (Double(Date().timeIntervalSince1970) - d.lastUpdate) > Double(60 * updateInterval) { writeBatteryInfo(id, "") }
                    getPencil(d: d)
                } else {
                    writeBatteryInfo(id, "")
                }
            }
        }

        // USB unplug: last BatteryIsCharging from USB can stick because Wi-Fi
        // refresh is skipped while lastUpdate is still fresh.
        clearStaleUSBCharging(usbIDs: usbIDs, networkIDs: networkIDs)
        lastUSBIDs = usbIDs
    }

    private func clearStaleUSBCharging(usbIDs: Set<String>, networkIDs: Set<String>) {
        let iDeviceTypes: Set<String> = ["iPhone", "iPad", "iPod"]
        for d in AirBatteryModel.getAll(noFilter: true) {
            guard iDeviceTypes.contains(d.deviceType) else { continue }
            guard !usbIDs.contains(d.deviceID) else { continue }
            // Only devices that were on USB last pass: a Wi-Fi-reported charging
            // flag (wall charger) is real and must not be cleared every scan.
            guard lastUSBIDs.contains(d.deviceID) else { continue }
            guard d.isCharging != 0 else { continue }

            // Clear USB charging immediately so we do not re-force a heavy
            // writeBatteryInfo/comptest every scan (that stalled Watch updates).
            var cleared = d
            cleared.isCharging = 0
            AirBatteryModel.updateDevice(cleared)

            // Then refresh level/charging over Wi-Fi when the device is reachable.
            if networkIDs.contains(d.deviceID) {
                writeBatteryInfo(d.deviceID, "-n")
            }

            // Keep paired Watch listed while the phone/pad is still known.
            touchChildWatches(of: d.deviceName)
        }
    }

    private func touchChildWatches(of parentName: String) {
        for child in AirBatteryModel.getAll(noFilter: true) where child.deviceType == "Watch" && child.parentName == parentName {
            AirBatteryModel.touchDevice(name: child.deviceName)
        }
    }
    
    /// Cheap Wi-Fi poll (battery domain only, no DeviceName/Watch query) so the
    /// real BatteryIsCharging flag is picked up within ~10-15 s instead of 60 s.

    /// iOS reports BatteryIsCharging=false once full (or on optimized-charging hold)
    /// while still plugged in; ExternalConnected stays true. Map that to 5
    /// ("plugged in, not charging"), which the UI draws with the plug icon.
    static func chargeState(_ lines: [String], charging: Bool) -> Int {
        if charging { return 1 }
        let ext = lines.first(where: { $0.contains("ExternalConnected") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces)
        return ext == "true" ? 5 : 0
    }

    private func quickBattery(_ id: String, _ d: Device) {
        guard let out = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: ["-n", "-u", id, "-q", "com.apple.mobile.battery"], timeout: 8) else { return }
        let b = out.components(separatedBy: .newlines)
        guard let lv = b.first(where: { $0.contains("BatteryCurrentCapacity") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces), let level = Int(lv),
              let cs = b.first(where: { $0.contains("BatteryIsCharging") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces), let charging = Bool(cs) else { return }
        var n = d
        n.batteryLevel = level
        n.isCharging = IDeviceBattery.chargeState(b, charging: charging)
        // keep lastUpdate so the full 60 s refresh (name/Watch) still runs
        if n.isCharging != d.isCharging { NSLog("AirBatteryTiming WiFi %@ charging %d -> %d", d.deviceName, d.isCharging, n.isCharging) }
        AirBatteryModel.updateDevice(n)
    }
    private var lastQuick: [String: Double] = [:]
    private var lastUSBIDs = Set<String>()

    func writeBatteryInfo(_ id: String, _ connectType: String) {
        //print("ℹ️ Getting Battery Info for \(id)")
        let lastUpdate = Date().timeIntervalSince1970
        if connectType == "" { _ = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/wificonnection", arguments: ["-u", id, "true"], timeout: 20) }
        if let deviceInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id], timeout: 30) {
            let i = deviceInfo.components(separatedBy: .newlines)
            if let deviceName = i.filter({ $0.contains("DeviceName") }).first?.components(separatedBy: ": ").last,
               let model = i.filter({ $0.contains("ProductType") }).first?.components(separatedBy: ": ").last,
               let type = i.filter({ $0.contains("DeviceClass") }).first?.components(separatedBy: ": ").last {
                if let batteryInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id, "-q", "com.apple.mobile.battery"], timeout: 30) {
                    let b = batteryInfo.components(separatedBy: .newlines)
                    // A timed-out ideviceinfo can return truncated output, so
                    // never force-unwrap the parsed values.
                    if let levelString = b.first(where: { $0.contains("BatteryCurrentCapacity") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let level = Int(levelString),
                       let chargingString = b.first(where: { $0.contains("BatteryIsCharging") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let charging = Bool(chargingString) {
                        AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: deviceName, deviceModel: model, batteryLevel: level, isCharging: IDeviceBattery.chargeState(b, charging: charging), lastUpdate: lastUpdate))
                        var watchUpdated = false
                        if let watchInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/comptest", arguments: [id], timeout: 30) {
                            let w = watchInfo.components(separatedBy: .newlines)
                            if let watchID = w.first(where: { $0.contains("Checking watch") })?.components(separatedBy: " ").last,
                               let watchName = w.first(where: { $0.contains("DeviceName") })?.components(separatedBy: ": ").last,
                               let watchModel = w.first(where: { $0.contains("ProductType") })?.components(separatedBy: ": ").last,
                               let watchLevelString = w.first(where: { $0.contains("BatteryCurrentCapacity") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                               let watchLevel = Int(watchLevelString),
                               let watchChargingString = w.first(where: { $0.contains("BatteryIsCharging") })?.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                               let watchCharging = Bool(watchChargingString) {
                                AirBatteryModel.updateDevice(Device(deviceID: watchID, deviceType: "Watch", deviceName: watchName, deviceModel: watchModel, batteryLevel: watchLevel, isCharging: watchCharging ? 1 : 0, parentName: deviceName, lastUpdate: lastUpdate))
                                watchUpdated = true
                            }
                        }
                        // comptest often fails over Wi-Fi; don't let the Watch age out
                        // while its parent iPhone/iPad is still online.
                        if !watchUpdated { touchChildWatches(of: deviceName) }
                    }
                }
            }
        }
    }
}

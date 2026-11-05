//
//  AirBatteryModel.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//

import Foundation

struct btdDevice: Codable, Equatable {
    let time: Date
    let vid: String
    let pid: String
    let type: String
    let mac: String
    let name: String
    let level: Int
}

struct Device: Hashable, Codable {
    var hasBattery: Bool = true
    var deviceID: String
    var deviceType: String
    var deviceName: String
    var deviceModel: String?
    var batteryLevel: Int
    var isCharging: Int
    var isCharged: Bool = false
    var isPaused: Bool = false
    var acPowered: Bool = false
    var isHidden: Bool = false
    var lowPower: Bool = false
    var parentName: String = ""
    var lastUpdate: Double
    var realUpdate: Double = 0.0
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(hasBattery)
        hasher.combine(deviceID)
        hasher.combine(deviceType)
        hasher.combine(deviceName)
        hasher.combine(deviceModel)
        hasher.combine(batteryLevel)
        hasher.combine(isCharging)
        hasher.combine(isCharged)
        hasher.combine(isPaused)
        hasher.combine(acPowered)
        hasher.combine(isHidden)
        hasher.combine(lowPower)
        hasher.combine(lastUpdate)
        hasher.combine(realUpdate)
        hasher.combine(parentName)
    }
}

class AirBatteryModel {
    private static let devicesLock = NSLock()
    private static let writeLock = NSLock()
    private static var storedDevices: [Device] = []
    static let machineType = ud.string(forKey: "machineType") ?? "Mac"
    static let key = "com.lihaoyun6.AirBattery.widget"
    
    // `Devices` is read by widget/UI code and written by several background
    // scanner threads (IOBluetooth callbacks, iDevice/Bluetooth scans).
    // Always take a consistent snapshot through this accessor.
    static var Devices: [Device] {
        get {
            devicesLock.lock()
            defer { devicesLock.unlock() }
            return storedDevices
        }
        set {
            devicesLock.lock()
            defer { devicesLock.unlock() }
            storedDevices = newValue
        }
    }

    static func updateDevice(_ device: Device) {
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(device.deviceName) { return }
        devicesLock.lock()
        defer { devicesLock.unlock() }
        //self.storedDevices.removeAll(where: {blockedItems.contains($0.deviceName)})
        var chargingChanged = false
        if let index = storedDevices.firstIndex(where: { $0.deviceName == device.deviceName }) {
            chargingChanged = storedDevices[index].isCharging != device.isCharging
            storedDevices[index] = device
        } else {
            storedDevices.append(device)
        }
        if chargingChanged, let hook = onChargingStateChange {
            DispatchQueue.main.async { hook() }
        }
    }

    /// Set by the app: called (on main) when any device's charging state flips,
    /// so the widget can be refreshed immediately instead of on the periodic timer.
    static var onChargingStateChange: (() -> Void)?
    
    static func touchDevice(name: String) {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        if let index = storedDevices.firstIndex(where: { $0.deviceName == name }) {
            storedDevices[index].lastUpdate = Date().timeIntervalSince1970
        }
    }

    static func hideDevice(_ name: String) {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        for index in storedDevices.indices {
            if storedDevices[index].deviceName == name {
                storedDevices[index].isHidden = true
            }
        }
    }
    
    static func unhideDevice(_ name: String) {
        devicesLock.lock()
        defer { devicesLock.unlock() }
        for index in storedDevices.indices {
            if storedDevices[index].deviceName == name {
                storedDevices[index].isHidden = false
            }
        }
    }
    
    static func getBlackList() -> [Device] {
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let devices = getAll(noFilter: true)
        return devices.filter({ blackList.contains($0.deviceName) })
    }
    
    static func getAll(reverse: Bool = false, noFilter: Bool = false) -> [Device] {
        let thisMac = ud.string(forKey: "deviceName")
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let now = Double(Date().timeIntervalSince1970)
        // Snapshot the shared array while holding the lock, then do the
        // filtering outside it so no lock is held while touching UserDefaults.
        devicesLock.lock()
        let snapshot = reverse ? Array(storedDevices.reversed()) : storedDevices
        devicesLock.unlock()
        var list = snapshot.filter { (now - $0.lastUpdate < Double(disappearTime * 60)) }
        if !noFilter { list = list.filter { !blackList.contains($0.deviceName) && !$0.isHidden } }
        var newList: [Device] = list.filter({ $0.parentName == thisMac })
        for d in list {
            if d.parentName == "" && d.parentName != thisMac {
                newList.append(d)
                for sd in list.filter({ $0.parentName == d.deviceName }) {
                    newList.append(sd)
                }
            }
        }
        for dd in list.filter({ !newList.contains($0) }) { newList.append(dd) }
        return newList.filter({ !checkIfBlocked(name: $0.deviceName) })
    }
    
    static func getByName(_ name: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceName == name { return d } }
        return nil
    }
    
    static func getByID(_ id: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceID == id { return d } }
        return nil
    }
    
    static func singleDeviceName() -> String {
        var url: URL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            url = fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("singleDeviceName")
            let devicename = try? String(contentsOf: url, encoding: .utf8)
            return devicename ?? ""
        } else {
            url = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/singleDeviceName")
            try? ud.string(forKey: "deviceOnWidget")?.write(to: url, atomically: true, encoding: .utf8)
        }
        return ""
    }
    
    static func getJsonURL() -> URL {
        // Prefer the widget container Documents path. Ad-hoc re-signing that
        // drops app-sandbox makes the widget's .documentDirectory resolve to
        // ~/Documents instead of the container — which looks like an empty
        // 8-ring widget even though Containers/.../data.json is populated.
        let containerURL = fd.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(key)/Data/Documents/data.json")
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            let docURL = fd.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("data.json")
            if fd.fileExists(atPath: docURL.path) { return docURL }
            if fd.fileExists(atPath: containerURL.path) { return containerURL }
            return docURL
        } else {
            return containerURL
        }
    }
    
    static func writeData(){
        //let showMac = ud.object(forKey: "showMacOnWidget") as? Bool ?? true
        let revList = ud.object(forKey: "revListOnWidget") as? Bool ?? false
        
        var devices = getAll(reverse: revList)
        let ibStatus = InternalBattery.status
        if ibStatus.hasBattery { devices.insert(ib2ab(ibStatus), at: 0) }
        do {
            let jsonData = try JSONEncoder().encode(devices)
            // This lock only serializes writers inside this process. The widget
            // extension is a separate process; .atomic is what prevents its
            // readers from seeing a partially written file.
            writeLock.lock()
            defer { writeLock.unlock() }
            try jsonData.write(to: getJsonURL(), options: .atomic)
        } catch {
            print("Write JSON error：\(error)")
        }
    }
    
    static func readData(url: URL = getJsonURL()) -> [Device]{
        do {
            let jsonData = try Data(contentsOf: url)
            let list = try JSONDecoder().decode([Device].self, from: jsonData)
            return list
        } catch {
            print("Read JSON error：\(error)")
        }
        return []
    }
    
    static func ncGetAll(url: URL, fromWidget: Bool = false) -> [Device] {
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let devices = readData(url: url)
        let now = Double(Date().timeIntervalSince1970)
        var localDevices = getAll().map({ $0.deviceName })
        if fromWidget { localDevices = readData().map({ $0.deviceName }) }
        var list = devices.filter{(now - $0.lastUpdate < Double(disappearTime * 60))}.filter({!localDevices.contains($0.deviceName)})
        if let first = devices.first { if !list.contains(first) && list.count != 0 { list.insert(first, at: 0) }}
        if let first = list.first { if list.count == 1 && !first.hasBattery { return [] }}
        return list
    }
    
    static func checkIfBlocked(name: String) -> Bool {
        let whitelistMode = ud.bool(forKey: "whitelistMode")
        let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        if (blockedItems.contains(name) && !whitelistMode) || (!blockedItems.contains(name) && whitelistMode) {
            return true
        }
        return false
    }
}

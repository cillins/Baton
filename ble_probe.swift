//
//  ble_probe.swift
//  Baton — Phase 0 research tool
//
//  Enumerates the Siri Remote's full GATT table and captures notify traffic
//  to determine whether a proprietary audio channel exists.
//  Logs to stdout AND /tmp/ble_probe.log.
//
//  Build: swiftc -o ble_probe ble_probe.swift -framework CoreBluetooth
//  Run:   ./ble_probe [listenSeconds]
//

import CoreBluetooth
import Foundation

let logPath = "/tmp/ble_probe.log"
func plog(_ s: String) {
    let line = "\(Date()) \(s)"
    print(line)
    if let d = (line + "\n").data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(d)
            try? fh.close()
        } else {
            try? d.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var listenSeconds: Double
    var readyAt: Date?
    var notifyCountByChar: [CBUUID: Int] = [:]

    init(listenSeconds: Double) {
        self.listenSeconds = listenSeconds
        super.init()
        plog("🚀 ble_probe starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        central = CBCentralManager(delegate: self, queue: nil)
        plog("…central manager created, waiting for state callback")
    }

    func match(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.contains("remote") || n.contains("siri") || n.contains("遥控器")
    }

    func connect(_ p: CBPeripheral) {
        peripheral = p
        plog("🔗 connecting to \(p.name ?? "?") [\(p.identifier.uuidString)]")
        central.stopScan()
        p.delegate = self
        central.connect(p, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            plog("✅ BLE poweredOn")
            // The remote is already system-connected as a BLE HID device;
            // retrieve it directly before falling back to a scan.
            let connected = central.retrieveConnectedPeripherals(withServices: [
                CBUUID(string: "1812"), // HID over GATT
                CBUUID(string: "180F"), // Battery
                CBUUID(string: "180A"), // Device Information
            ])
            plog("retrieveConnectedPeripherals → \(connected.count): \(connected.map { "\($0.name ?? "?") [\($0.identifier.uuidString)]" })")
            if let p = connected.first(where: { match($0.name) }) ?? connected.first {
                connect(p)
                return
            }
            plog("🔍 scanning for remote…")
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self, self.peripheral == nil else { return }
                central.stopScan()
                plog("⛔ no matching peripheral found via scan")
                exit(2)
            }
        case .unauthorized:
            plog("⛔ Bluetooth UNAUTHORIZED — grant Bluetooth permission to this terminal in System Settings → Privacy & Security → Bluetooth")
            exit(3)
        case .poweredOff:
            plog("⛔ Bluetooth powered off")
            exit(4)
        default:
            plog("central state=\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        plog("📡 adv: \(name ?? "?") [\(p.identifier.uuidString)] rssi=\(RSSI)")
        if peripheral == nil, match(name) {
            connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        plog("✅ connected — discovering services…")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        plog("⛔ connect failed: \(error?.localizedDescription ?? "?")")
        exit(5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        plog("⚠️ disconnected (\(error?.localizedDescription ?? "clean")) — reconnecting…")
        central.connect(p, options: nil)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { plog("⚠️ service discovery error: \(error.localizedDescription)") }
        for s in p.services ?? [] {
            plog("🧩 service \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            plog("   • char \(c.uuid) props=\(c.properties)")
            if c.properties.contains(.read) { p.readValue(for: c) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                p.setNotifyValue(true, for: c)
            }
            p.discoverDescriptors(for: c)
        }
        let allDone = (p.services ?? []).allSatisfy { $0.characteristics != nil }
        if allDone, readyAt == nil {
            readyAt = Date()
            plog("👂 READY — now hold the Siri button and speak. Listening \(Int(listenSeconds))s…")
            DispatchQueue.main.asyncAfter(deadline: .now() + listenSeconds) { [weak self] in
                self?.dumpSummary()
                plog("🏁 done")
                exit(0)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor c: CBCharacteristic, error: Error?) {
        for d in c.descriptors ?? [] {
            plog("     ◦ desc \(d.uuid)")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let data = c.value ?? Data()
        let hex = data.map { String(format: "%02x", $0) }.joined()
        notifyCountByChar[c.uuid, default: 0] += 1
        plog("📥 \(c.service?.uuid ?? CBUUID())/\(c.uuid) len=\(data.count) \(hex)")
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        plog("🔔 notify \(c.service?.uuid ?? CBUUID())/\(c.uuid) → \(c.isNotifying)")
    }

    func dumpSummary() {
        plog("📊 notify traffic summary (char → packet count):")
        for (uuid, count) in notifyCountByChar.sorted(by: { $0.value > $1.value }) {
            plog("   \(uuid): \(count)")
        }
    }
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
_ = Probe(listenSeconds: seconds)
RunLoop.main.run()

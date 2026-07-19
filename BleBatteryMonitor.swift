//
//  BleBatteryMonitor.swift
//  Baton
//
//  Lightweight CoreBluetooth client that watches the standard BLE Battery
//  Service (0x180F / Battery Level 0x2A19) on the connected Siri Remote and
//  pushes percentage updates through a closure. The IOHID stack doesn't
//  expose battery for Bluetooth HID devices, so we keep a parallel GATT
//  connection solely for this one characteristic. macOS allows multiple
//  BLE links to the same peripheral, so the HID side keeps working.
//

import CoreBluetooth
import Foundation

final class BleBatteryMonitor: NSObject {
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelCharUUID = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var onBattery: ((Int?) -> Void)?

    func start(onBattery: @escaping (Int?) -> Void) {
        self.onBattery = onBattery
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    /// Re-run the retrieve/scan dance. Called at startup and whenever the HID
    /// side detects the remote (re)connecting — a remote that was asleep at
    /// launch is missed by the initial retrieve, and once the OS owns the
    /// GATT link it stops advertising, so scanning alone never finds it.
    func refresh() {
        guard let central = central, central.state == .poweredOn else { return }
        guard peripheral == nil else { return }
        central.stopScan()
        // Path 1: the remote is already connected at the OS level (HID-over-GATT).
        // On some macOS versions CoreBluetooth sees it; on others it doesn't.
        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.batteryServiceUUID]
        )
        rmDebug("🔋 retrieved \(connected.count) battery-service peripheral(s)")
        if let remote = connected.first(where: {
            let n = $0.name ?? ""
            return n.localizedCaseInsensitiveContains("remote") || n.contains("遥控器")
        }) ?? connected.first {
            peripheral = remote
            remote.delegate = self
            central.connect(remote, options: nil)
            return
        }
        // Path 2: fall back to a service-filtered scan. Scanning for a specific
        // service UUID does NOT trigger the "Bluetooth is scanning" privacy
        // prompt (that only fires for unfiltered scans), so this is safe to
        // run silently. We stop scanning as soon as the first match connects.
        rmDebug("🔋 starting service-filtered scan for 0x180F")
        central.scanForPeripherals(
            withServices: [Self.batteryServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}

extension BleBatteryMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            rmDebug("🔋 battery monitor state=\(central.state.rawValue)")
            return
        }
        refresh()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? ""
        rmDebug("🔋 scan hit: \(name) [\(peripheral.identifier.uuidString.prefix(8))]")
        // Prefer devices whose name looks like the remote; fall back to first hit.
        let looksRemote = name.localizedCaseInsensitiveContains("remote") || name.contains("遥控器")
        guard looksRemote || self.peripheral == nil else { return }
        rmDebug("🔋 stopping scan, connecting to \(name)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        rmDebug("🔋 battery didConnect \(peripheral.name ?? "?")")
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        rmDebug("🔋 battery didFailToConnect: \(error?.localizedDescription ?? "?")")
        if self.peripheral === peripheral {
            self.peripheral = nil
            // Try again from scratch — the OS may have released the previous GATT link.
            central.scanForPeripherals(
                withServices: [Self.batteryServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rmDebug("🔋 battery didDisconnect: \(error?.localizedDescription ?? "ok")")
        if self.peripheral === peripheral {
            self.peripheral = nil
            onBattery?(nil)
            // Rescan so a future reconnect re-establishes the notify.
            central.scanForPeripherals(
                withServices: [Self.batteryServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }
}

extension BleBatteryMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] where svc.uuid == Self.batteryServiceUUID {
            peripheral.discoverCharacteristics([Self.batteryLevelCharUUID], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.batteryLevelCharUUID {
            peripheral.setNotifyValue(true, for: c)
            // Also pull the current value once instead of waiting for the next notify tick.
            peripheral.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevelCharUUID,
              let data = characteristic.value,
              let pct = data.first else { return }
        onBattery?(Int(pct))
    }
}

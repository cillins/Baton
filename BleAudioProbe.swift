//
//  BleAudioProbe.swift
//  Baton — Phase 0 research tool
//
//  CoreBluetooth counterpart to AudioProbe. Standalone BLE probing was blocked by
//  TCC (centralManagerDidUpdateState never fired in an ad-hoc CLI), but Baton.app
//  holds a Bluetooth grant, so inside the app we can enumerate the remote's GATT
//  table — most importantly the Apple-proprietary service
//  8341F2B4-C013-4F04-8197-C4CDB42E26DC, which public reverse engineering suggests
//  may gate or carry the voice stream. We subscribe to every notifiable
//  characteristic and log all values to the shared probe log.
//
//  Enabled with --audio-probe (started alongside AudioProbe).
//

import CoreBluetooth
import Foundation

final class BleAudioProbe: NSObject {
    static let shared = BleAudioProbe()

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private let hidServiceUUID    = CBUUID(string: "1812")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let appleServiceUUID  = CBUUID(string: "8341F2B4-C013-4F04-8197-C4CDB42E26DC")

    func start() {
        guard central == nil else { return }
        AudioProbe.shared.log("📡 BLE probe starting (CoreBluetooth inside Baton)")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func log(_ s: String) { AudioProbe.shared.log(s) }
}

extension BleAudioProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("📡 central state=\(central.state.rawValue)")
        guard central.state == .poweredOn else { return }

        // The remote is already connected at the OS level (HID over GATT), so it
        // should be retrievable without scanning. Try several services it hosts.
        let connected = central.retrieveConnectedPeripherals(withServices: [
            hidServiceUUID, batteryServiceUUID, appleServiceUUID,
        ])
        log("📡 retrieveConnectedPeripherals → \(connected.count)")
        for p in connected {
            log("📡   connected: name=\(p.name ?? "?") id=\(p.identifier)")
        }

        let remote = connected.first(where: {
            let n = $0.name ?? ""
            return n.localizedCaseInsensitiveContains("remote") || n.contains("遥控器")
        }) ?? connected.first

        guard let remote = remote else {
            log("⚠️ BLE probe: remote not found among connected peripherals")
            return
        }
        peripheral = remote
        remote.delegate = self
        // A retrieved peripheral is connected at the system level; GATT operations
        // need an app-level connection first, otherwise discovery never completes.
        central.connect(remote, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("📡 didConnect \(peripheral.name ?? "?")")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("⚠️ didFailToConnect: \(error?.localizedDescription ?? "?")")
    }
}

extension BleAudioProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("⚠️ discoverServices: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        log("📡 services (\(services.count)):")
        for s in services {
            log("📡   service \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("⚠️ discoverCharacteristics \(service.uuid): \(error.localizedDescription)")
            return
        }
        for c in service.characteristics ?? [] {
            log("📡     char \(c.uuid) props=0x\(String(c.properties.rawValue, radix: 16))")
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let state = characteristic.isNotifying ? "ON" : "OFF"
        if let error = error {
            log("⚠️ notify \(state) failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("📡 notify \(state): \(characteristic.service?.uuid ?? CBUUID())/\(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("⚠️ value \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        let hex = data.map { String(format: "%02x", $0) }.joined()
        log("📥 BLE \(characteristic.service?.uuid ?? CBUUID())/\(characteristic.uuid) len=\(data.count) \(hex)")
    }
}

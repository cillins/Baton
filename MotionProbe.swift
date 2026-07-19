//
//  MotionProbe.swift
//  Baton — Phase 0 research tool (gen-1 accelerometer/gyro feasibility)
//
//  Question: does the Siri Remote (A1513) stream motion data to macOS through
//  any user-space-reachable path?
//    Path A: HID input elements on the seized interfaces (game-controls page
//            or Apple vendor page). Motion would show up as high-frequency,
//            continuously varying Misc/Axis values while the remote is waved.
//    Path B: Game Controller framework (GCController + GCMotion).
//
//  Enabled via launch flag: --motion-probe
//  Log: /tmp/motion_probe.log (also stdout)
//

import IOKit
import IOKit.hid
import Foundation
import GameController

final class MotionProbe {
    static let shared = MotionProbe()

    private let logPath = "/tmp/motion_probe.log"
    private var attached: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    /// Per-element value stats, flushed every 2s: (count, min, max, last).
    private var stats: [String: (count: Int, min: Int, max: Int, last: Int)] = [:]
    private var statsTimer: DispatchSourceTimer?
    private let statsQueue = DispatchQueue(label: "motionprobe.stats")
    private var keepaliveTimer: DispatchSourceTimer?

    func log(_ s: String) {
        let line = "\(Date()) \(s)\n"
        print(s)
        if let d = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(d)
                try? fh.close()
            } else {
                try? d.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    // MARK: - Path A: raw HID elements

    func attach(_ device: IOHIDDevice) {
        guard !attached.contains(where: { $0 == device }) else { return }
        attached.append(device)

        let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        log(String(format: "🧭 motion probe attach: vendor=0x%X product=0x%X", v, p))

        dumpInputElements(device)

        // Raw report callback: motion payloads (24B / 48B) would be truncated by
        // the per-element value path context — capture full report bytes too.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        buffers.append(buffer) // keep alive for process lifetime (probe tool)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, reportCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputValueCallback(device, valueCallback,
                                              Unmanaged.passUnretained(self).toOpaque())
        log("🧭 report + value callbacks registered")

        // Motion enable (from retsyx/SiriRemote): write A0 01 to GATT handle
        // 0x001d — the same buffered-bytes FEATURE pipe (report 255) the 0xAF
        // audio enable uses, which we've verified works from macOS user space.
        sendMotionEnable(device)
        startKeepalive()
        startStatsTimer()
    }

    private func sendMotionEnable(_ device: IOHIDDevice) {
        var payload: [UInt8] = [0xA0, 0x01]
        var r = payload.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, 2)
        }
        log(String(format: "📤 motion enable: FEATURE id=255 [A0 01] → IOReturn=0x%X", r))
        if r != kIOReturnSuccess {
            var full = [UInt8](repeating: 0, count: 208)
            full[0] = 0xA0
            full[1] = 0x01
            r = full.withUnsafeBufferPointer { ptr in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, 208)
            }
            log(String(format: "📤 motion enable: FEATURE id=255 208-byte → IOReturn=0x%X", r))
        }
    }

    /// retsyx sends F0 7F to handle 0x001d every ~50s to keep streaming alive.
    private func startKeepalive() {
        guard keepaliveTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "motionprobe.keepalive"))
        t.schedule(deadline: .now() + 45, repeating: 45.0)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            for device in self.attached {
                var payload: [UInt8] = [0xF0, 0x7F]
                let r = payload.withUnsafeBufferPointer { ptr in
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, 2)
                }
                if r == kIOReturnSuccess {
                    self.log("📤 motion keepalive sent")
                }
            }
        }
        keepaliveTimer = t
        t.resume()
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        let data = Data(bytes: report, count: length)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        log(String(format: "📥 report id=%d len=%d %@", reportID, length, hex))
    }

    /// Log every input element with its logical range — motion axes would be
    /// declared as wide-range (e.g. ±32767) Misc/Axis inputs, likely on the
    /// Generic Desktop page (0x01: X/Y/Z 0x30-0x32, Rx/Ry/Rz 0x33-0x35) or an
    /// Apple vendor page.
    private func dumpInputElements(_ device: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            log("⚠️ IOHIDDeviceCopyMatchingElements returned nil")
            return
        }
        for el in elements {
            let t = IOHIDElementGetType(el)
            guard t == kIOHIDElementTypeInput_Misc || t == kIOHIDElementTypeInput_Axis else { continue }
            log(String(format: "📄 elem page=0x%X usage=0x%X reportID=%d bits=%d count=%d logical=%ld...%ld",
                       IOHIDElementGetUsagePage(el), IOHIDElementGetUsage(el),
                       IOHIDElementGetReportID(el),
                       IOHIDElementGetReportSize(el), IOHIDElementGetReportCount(el),
                       IOHIDElementGetLogicalMin(el), IOHIDElementGetLogicalMax(el)))
        }
    }

    fileprivate func handleValue(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let v = IOHIDValueGetIntegerValue(value)
        let key = String(format: "%X:%X", page, usage)
        statsQueue.async {
            var s = self.stats[key] ?? (0, Int.max, Int.min, 0)
            s.count += 1
            s.min = Swift.min(s.min, v)
            s.max = Swift.max(s.max, v)
            s.last = v
            self.stats[key] = s
        }
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: statsQueue)
        t.schedule(deadline: .now() + 2, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.flushStats() }
        statsTimer = t
        t.resume()
    }

    /// Elements firing more than ~10×/2s are streamers (motion, touch), not buttons.
    private func flushStats() {
        for (key, s) in stats.sorted(by: { $0.value.count > $1.value.count }) where s.count > 10 {
            log(String(format: "📊 %@ ×%d min=%ld max=%ld last=%ld", key, s.count, s.min, s.max, s.last))
        }
        stats.removeAll(keepingCapacity: true)
    }

    // MARK: - Path B: Game Controller framework

    func startGameControllerProbe() {
        let ctrls = GCController.controllers()
        log("🎮 GCController count=\(ctrls.count)")
        for c in ctrls { describe(c) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            if let c = note.object as? GCController {
                MotionProbe.shared.log("🎮 GC connected: \(c.vendorName ?? "?")")
                MotionProbe.shared.describe(c)
            }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            if let c = note.object as? GCController {
                MotionProbe.shared.log("🎮 GC disconnected: \(c.vendorName ?? "?")")
            }
        }
    }

    private func describe(_ c: GCController) {
        log("🎮 controller: vendor=\(c.vendorName ?? "?") category=\(c.productCategory) motion=\(c.motion != nil)")
        if let m = c.motion {
            m.valueChangedHandler = { motion in
                MotionProbe.shared.logMotion(motion)
            }
        }
    }

    private var motionLogCount = 0
    fileprivate func logMotion(_ m: GCMotion) {
        motionLogCount += 1
        guard motionLogCount % 30 == 1 else { return }
        log(String(format: "🧭 GC gravity=(%.3f %.3f %.3f) user=(%.3f %.3f %.3f) gyro=(%.3f %.3f %.3f)",
                   m.gravity.x, m.gravity.y, m.gravity.z,
                   m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z,
                   m.rotationRate.x, m.rotationRate.y, m.rotationRate.z))
    }
}

private func valueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                           sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<MotionProbe>.fromOpaque(context).takeUnretainedValue().handleValue(value)
}

private func reportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                            sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                            reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                            reportLength: CFIndex) {
    guard let context = context else { return }
    Unmanaged<MotionProbe>.fromOpaque(context).takeUnretainedValue()
        .handleReport(report, length: reportLength, reportID: reportID)
}

//
//  MotionCapture.swift
//  Baton
//
//  Gen-1 Siri Remote (A1513) gyro capture, production version of the
//  --motion-probe research tool. Protocol (from retsyx/SiriRemote + our
//  probe verification): enable motion by writing `A0 01` as FEATURE report
//  255 (GATT handle 0x001d), keep alive with `F0 7F` every 45s. Motion then
//  streams continuously as 25-byte raw reports (ID 1) on the vendor-page
//  interface; gyro X/Y/Z are signed LE int16 at payload bytes 18-23.
//  Gen 2/3 remotes have no motion hardware — only attach for gen 1.
//

import IOKit
import IOKit.hid
import Foundation

final class MotionCapture {
    /// Gyro rates in raw sensor units, delivered on the IOHID callback thread.
    /// (~50-90Hz while streaming.)
    var onGyro: ((_ x: Int16, _ y: Int16, _ z: Int16, _ timestamp: UInt64) -> Void)?

    private var attached: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var keepaliveTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var lastMotionReportNanos: UInt64 = 0
    private var lastEnableAttemptNanos: UInt64 = 0
    private let queue = DispatchQueue(label: "com.baton.motion")

    func attach(_ device: IOHIDDevice) {
        queue.async {
            let usagePage = IOHIDDeviceGetProperty(
                device, kIOHIDPrimaryUsagePageKey as CFString
            ) as? Int ?? -1
            guard usagePage == 0xFF00 else {
                rmDebug(String(format: "🌀 skipping non-vendor HID interface usagePage=0x%X", usagePage))
                return
            }
            guard !self.attached.contains(where: { $0 == device }) else { return }
            self.attached.append(device)

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
            self.buffers.append(buffer)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, motionReportCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
            self.lastMotionReportNanos = 0
            self.enableMotion(device, reason: "device ready")
            self.startKeepalive()
            self.startRecoveryMonitor()
        }
    }

    func detach() {
        queue.async {
            for device in self.attached {
                self.setReport(device, [0xA0, 0x00], label: "motion disable")
            }
            self.attached.removeAll()
            self.lastMotionReportNanos = 0
            self.lastEnableAttemptNanos = 0
            self.keepaliveTimer?.cancel()
            self.keepaliveTimer = nil
            self.recoveryTimer?.cancel()
            self.recoveryTimer = nil
        }
    }

    @discardableResult
    private func setReport(_ device: IOHIDDevice, _ payload: [UInt8], label: String) -> IOReturn {
        let bytes = payload
        let r = bytes.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, bytes.count)
        }
        if r != kIOReturnSuccess {
            rmDebug("🌀 \(label) failed: IOReturn=0x\(String(r, radix: 16))")
        }
        return r
    }

    private func enableMotion(_ device: IOHIDDevice, reason: String) {
        lastEnableAttemptNanos = DispatchTime.now().uptimeNanoseconds
        let result = setReport(device, [0xA0, 0x01], label: "motion enable (\(reason))")
        if result == kIOReturnSuccess {
            rmDebug("🌀 motion enable sent (\(reason))")
        }
    }

    private func startKeepalive() {
        guard keepaliveTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 45, repeating: 45.0)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            for device in self.attached {
                self.setReport(device, [0xF0, 0x7F], label: "motion keepalive")
            }
        }
        keepaliveTimer = t
        t.resume()
    }

    /// A successful FEATURE write does not guarantee that the BLE transport
    /// has begun delivering reports. Fresh TCC grants and remote wake-up can
    /// leave it temporarily not ready, so recover without requiring an app
    /// restart whenever no motion packet arrives after an enable attempt.
    private func startRecoveryMonitor() {
        guard recoveryTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self, !self.attached.isEmpty else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let reference = max(self.lastMotionReportNanos, self.lastEnableAttemptNanos)
            guard reference == 0 || now - reference >= 2_000_000_000 else { return }
            for device in self.attached {
                self.enableMotion(device, reason: "no motion reports")
            }
        }
        recoveryTimer = t
        t.resume()
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        // Layout: byte 0 = report ID (0x01), payload bytes 1-24.
        // Gyro X/Y/Z = signed LE int16 at payload 18-23 → buffer offsets 19-24.
        guard reportID == 1, length == 25 else { return }
        // Timestamp at acquisition, before optional probe logging or a hop to
        // the main queue. Main-thread scheduling latency must not change the
        // angular distance represented by this sample.
        let timestamp = mach_absolute_time()
        queue.async { [weak self] in
            self?.lastMotionReportNanos = DispatchTime.now().uptimeNanoseconds
        }
        let x = Int16(bitPattern: UInt16(report[19]) | UInt16(report[20]) << 8)
        let y = Int16(bitPattern: UInt16(report[21]) | UInt16(report[22]) << 8)
        let z = Int16(bitPattern: UInt16(report[23]) | UInt16(report[24]) << 8)
        logFields(report, x: x, y: y, z: z)
        onGyro?(x, y, z, timestamp)
    }

    // MARK: - Field identification probe (--motion-fields)
    //
    // Logs the unidentified payload fields as CSV to /tmp/motion_fields.csv:
    // ts, f0..f2 (payload 0-11 as float32 LE), b12..b17 (raw ints), gyro xyz.
    // Hypotheses: f0-f2 = accelerometer (constant ~1g magnitude at rest,
    // gravity moves between axes with orientation) or quaternion components
    // (bounded [-1,1], smooth with attitude).

    private var fieldsLogInitialized = false

    private func logFields(_ report: UnsafeMutablePointer<UInt8>, x: Int16, y: Int16, z: Int16) {
        guard CommandLine.arguments.contains("--motion-fields") else { return }
        func f(_ o: Int) -> Float {
            let bits = UInt32(report[o]) | UInt32(report[o+1]) << 8 | UInt32(report[o+2]) << 16 | UInt32(report[o+3]) << 24
            return Float(bitPattern: bits)
        }
        let line = String(format: "%.3f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                          Date().timeIntervalSince1970,
                          f(1), f(5), f(9),
                          report[13], report[14], report[15], report[16], report[17], report[18],
                          x, y, z)
        let path = "/tmp/motion_fields.csv"
        if !fieldsLogInitialized {
            fieldsLogInitialized = true
            try? "ts,f0,f1,f2,b12,b13,b14,b15,b16,b17,gx,gy,gz\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
    }
}

private func motionReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                                  sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                                  reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                  reportLength: CFIndex) {
    guard let context = context else { return }
    Unmanaged<MotionCapture>.fromOpaque(context).takeUnretainedValue()
        .handleReport(report, length: reportLength, reportID: reportID)
}

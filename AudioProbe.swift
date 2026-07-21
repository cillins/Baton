//
//  AudioProbe.swift
//  Baton — Phase 0 research tool
//
//  RESULT (2026-07-17, remote A1513 fw 0100570220): the mic stream is NOT reachable
//  via any public macOS API.
//  - Buttons/touch/audio all ride one GATT characteristic (handle 0x23), which macOS
//    binds to HID report 250 — declared as a 1-byte payload in the report map, so the
//    HID parser drops the 101-byte Opus frames before user space. During a 5s Siri
//    hold, only 1-byte button reports (fa10/fa00) ever reached the callback.
//  - The 208-byte buffered-bytes pipes (IN/FEAT report 255 on 3 interfaces) polled
//    every 20ms during the hold returned constant `ff` — not an audio FIFO.
//  - CoreBluetooth (BleAudioProbe, with Bluetooth TCC grant) only sees Device
//    Information + Battery services; macOS filters the HID service and the Apple
//    proprietary service 8341F2B4 from third-party apps.
//  The only remaining capture path is HCI-level sniffing: PacketLogger (Additional
//  Tools for Xcode, sudo) → parse ATT notifications → Opus decode → virtual mic.
//  That is the architecture Jack-R1's SiriRemoteVoiceControl proved.
//
//  Enabled via launch flags:
//    --audio-probe            observe: dump descriptors + log all reports
//    --audio-enable=<id>      also send 0xAF as an output report to report ID <id>
//                             (decimal or 0x-hex) on every attached device
//

import IOKit
import IOKit.hid
import Foundation

final class AudioProbe {
    static let shared = AudioProbe()

    private let logPath = "/tmp/hid_audio_probe.log"
    private var attached: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var callbackContexts: [AudioReportContext] = []
    private var audioDeviceIndex: Int?
    private var siriHeld = false

    /// 0xAF enable target, parsed from --audio-enable=<id>. nil = don't send.
    let enableReportID: CFIndex? = {
        for arg in CommandLine.arguments where arg.hasPrefix("--audio-enable=") {
            let raw = String(arg.dropFirst("--audio-enable=".count))
            let value = raw.hasPrefix("0x") ? Int(raw.dropFirst(2), radix: 16) : Int(raw)
            if let value = value { return value as CFIndex }
        }
        return nil
    }()

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

    func attach(_ device: IOHIDDevice) {
        guard !attached.contains(where: { $0 == device }) else { return }
        attached.append(device)
        let deviceIndex = attached.count - 1

        let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        log(String(format: "🎧 probe attach: vendor=0x%X product=0x%X transport=%@", v, p, transport))

        let handlesSiriState = dumpReportElements(device)

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        buffers.append(buffer) // keep alive for process lifetime (probe tool)
        let callbackContext = AudioReportContext(
            probe: self,
            deviceIndex: deviceIndex,
            handlesSiriState: handlesSiriState
        )
        callbackContexts.append(callbackContext)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, inputReportCallback,
                                               Unmanaged.passUnretained(callbackContext).toOpaque())
        log("🎧 raw report callback registered dev=\(deviceIndex) siriState=\(handlesSiriState)")

        if handlesSiriState {
            audioDeviceIndex = deviceIndex
        }
        // Do not enable during enumeration.  The remote exposes six HID interfaces,
        // and writes while they are still arriving can reset the Siri state stream.
        // A real Siri-down transition broadcasts one enable command after all of the
        // interfaces have attached.
    }

    private func sendEnable(_ device: IOHIDDevice) {
        var payload: [UInt8] = [0xAF]
        var r = payload.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, 1)
        }
        log(String(format: "📤 enable: FEATURE id=255 [0xAF] → IOReturn=0x%X", r))
        if r != kIOReturnSuccess {
            // Some stacks require the full declared report size (208 bytes).
            var full = [UInt8](repeating: 0, count: 208)
            full[0] = 0xAF
            r = full.withUnsafeBufferPointer { ptr in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 255, ptr.baseAddress!, 208)
            }
            log(String(format: "📤 enable: FEATURE id=255 208-byte [0xAF…] → IOReturn=0x%X", r))
        }
        payload.withUnsafeBufferPointer { _ in } // keep payload alive semantics explicit
    }

    private func sendEnableToAllInterfaces() {
        log("📤 broadcasting one enable command to \(attached.count) interface(s)")
        for (index, device) in attached.enumerated() {
            log("📤 enable target dev=\(index)")
            sendEnable(device)
        }
    }

    /// Log aggregated report IDs with total payload size (audio ≈100 bytes), plus the
    /// raw HID report descriptor for manual parsing. Input element types are
    /// Misc/Button/Axis/ScanCodes (1/2/3/4); Output=129, Feature=257.
    private func dumpReportElements(_ device: IOHIDDevice) -> Bool {
        if let desc = IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data {
            log("📄 report descriptor (\(desc.count) bytes): \(desc.map { String(format: "%02x", $0) }.joined())")
        }
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            log("⚠️ IOHIDDeviceCopyMatchingElements returned nil")
            return false
        }
        // (class, reportID) → (totalBits, sample pages/usages)
        var reports: [String: (bits: Int, detail: String)] = [:]
        var hasSiriInput = false
        for el in elements {
            let t = IOHIDElementGetType(el)
            let cls: String
            switch t {
            case kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Button,
                 kIOHIDElementTypeInput_Axis, kIOHIDElementTypeInput_ScanCodes:
                cls = "IN"
            case kIOHIDElementTypeOutput:
                cls = "OUT"
            case kIOHIDElementTypeFeature:
                cls = "FEAT"
            default:
                continue
            }
            let rid = IOHIDElementGetReportID(el)
            if cls == "IN", rid == 250 {
                hasSiriInput = true
            }
            let size = IOHIDElementGetReportSize(el)
            let count = IOHIDElementGetReportCount(el)
            let key = "\(cls):\(rid)"
            var entry = reports[key] ?? (0, "")
            entry.bits += Int(size) * Int(count)
            if entry.detail.count < 40 {
                entry.detail += String(format: " [0x%X:0x%X]", IOHIDElementGetUsagePage(el), IOHIDElementGetUsage(el))
            }
            reports[key] = entry
        }
        for (key, entry) in reports.sorted(by: { $0.key < $1.key }) {
            log(String(format: "📄 %@ report: %d bits (≈%d bytes)%@", key, entry.bits, entry.bits / 8, entry.detail))
        }
        return hasSiriInput
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int,
                                  reportID: UInt32, deviceIndex: Int,
                                  handlesSiriState: Bool) {
        let data = Data(bytes: report, count: length)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        log(String(format: "📥 report dev=%d id=%d len=%d %@", deviceIndex, reportID, length, hex))

        guard handlesSiriState, reportID == 250 else { return }
        if data == Data([0xfa, 0x10]), !siriHeld {
            siriHeld = true
            log("📤 Siri down dev=\(deviceIndex) — enabling once")
            if enableReportID != nil {
                sendEnableToAllInterfaces()
            }
            startPolling()
        } else if data == Data([0xfa, 0x00]), siriHeld {
            siriHeld = false
            log("📤 Siri up dev=\(deviceIndex)")
            stopPolling()
        }
    }

    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "audioprobe.poll")
    private var lastPollData: [String: Data] = [:]

    private func startPolling() {
        guard pollTimer == nil else { return }
        log("📤 Siri held — polling all buffered-bytes report 255 interfaces")
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.pollBufferedBytes() }
        pollTimer = t
        t.resume()
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        lastPollData.removeAll()
    }

    private func pollBufferedBytes() {
        for (deviceIndex, device) in attached.enumerated() {
            for (typeName, type) in [("IN", kIOHIDReportTypeInput), ("FEAT", kIOHIDReportTypeFeature)] {
                var buf = [UInt8](repeating: 0, count: 512)
                var len = buf.count
                let r = IOHIDDeviceGetReport(device, type, 255, &buf, &len)
                guard r == kIOReturnSuccess, len > 0 else { continue }
                let d = Data(buf[0..<len])
                guard d.contains(where: { $0 != 0 }) else { continue }
                let key = "\(deviceIndex)-\(typeName)"
                guard lastPollData[key] != d else { continue }
                lastPollData[key] = d
                let hex = d.map { String(format: "%02x", $0) }.joined()
                log(String(format: "📥 poll dev=%d %@:255 len=%d %@", deviceIndex, typeName, len, hex))
            }
        }
    }
}

private final class AudioReportContext {
    unowned let probe: AudioProbe
    let deviceIndex: Int
    let handlesSiriState: Bool

    init(probe: AudioProbe, deviceIndex: Int, handlesSiriState: Bool) {
        self.probe = probe
        self.deviceIndex = deviceIndex
        self.handlesSiriState = handlesSiriState
    }
}

private func inputReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                                 sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                                 reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                 reportLength: CFIndex) {
    guard let context = context else { return }
    let callbackContext = Unmanaged<AudioReportContext>.fromOpaque(context).takeUnretainedValue()
    callbackContext.probe.handleReport(
        report,
        length: reportLength,
        reportID: reportID,
        deviceIndex: callbackContext.deviceIndex,
        handlesSiriState: callbackContext.handlesSiriState
    )
}

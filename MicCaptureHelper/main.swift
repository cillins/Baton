//
//  BatonMicCaptureHelper
//
//  Privileged, deliberately narrow bridge to Apple's PacketLogger live trace.
//  It forwards only validated A1962 Opus payloads from ATT handle 0x0023.
//

import Foundation
import Darwin
import OSLog
import Security

private let captureLogger = Logger(subsystem: "com.baton.miccapture", category: "Capture")

private final class CaptureService: NSObject, RemoteMicrophoneCaptureServiceProtocol {
    private weak var connection: NSXPCConnection?
    private var packetLogger: Process?
    private var pendingStartReply: ((Bool, String?) -> Void)?
    private var pendingOutput = Data()
    private var pendingRecord: String?
    private let parseQueue = DispatchQueue(label: "com.baton.miccapture.parser")
    private var receivedByteCount = 0
    private var receivedLineCount = 0
    private var receivedATTCount = 0
    private var handle23Count = 0
    private var audioHeaderCount = 0
    private var forwardedFrameCount = 0
    private var rejectionDiagnosticSent = false
    private var activationWriteCount = 0
    private var keyRecordDiagnosticCount = 0
    private var activationTraceRemaining = 0
    private var postAudioRawDiagnosticCount = 0
    private var awaitingActivationWriteResponse = false
    private var fragmentDiagnosticCount = 0
    private struct FragmentedAudioFrame {
        var bytes: [UInt8]
        let expectedByteCount: Int
        let connectionHandle: UInt16
    }
    private var fragmentedAudioFrame: FragmentedAudioFrame?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("Baton microphone capture helper ready")
    }

    func startCapture(reply: @escaping (Bool, String?) -> Void) {
        parseQueue.async { [weak self] in
            guard let self else { return }
            if self.packetLogger != nil {
                reply(true, nil)
                return
            }
            do {
                // A force-quit/relaunch can invalidate the XPC connection
                // before its old CaptureService finishes cleanup. Since this
                // helper only spawns PacketLogger through `script`, remove any
                // capture children left by an earlier client before starting
                // the new session.
                for child in Self.childPIDs(of: getpid()) {
                    Self.terminateProcessTree(rootPID: child)
                }
                let executable = try Self.validatedPacketLoggerURL()
                let process = Process()
                // PacketLogger only emits live text incrementally when stdout is a
                // terminal. A Pipe makes it buffer (or suppress) the stream until
                // capture ends, which is useless for a live microphone. `script`
                // supplies a fixed local PTY while preserving a pipe back to Baton.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
                process.arguments = [
                    "-q", "/dev/null", executable.path,
                    // Do not request buffered packets here. That option emits
                    // an ATT notification as soon as its first controller
                    // fragment arrives (only the 1010 header), before
                    // PacketLogger has reassembled the remaining L2CAP data.
                    // Normal live conversion waits and supplies the complete
                    // multi-packet raw frame, matching offline conversion.
                    "convert", "--stdout",
                    "--format", "itpnahdsr"
                ]
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self?.parseQueue.async {
                        guard let self else { return }
                        // Process.run() only means `script` was spawned. Wait
                        // until PacketLogger actually emits live HCI data before
                        // telling Baton to send the microphone handshake.
                        if let ready = self.pendingStartReply {
                            self.pendingStartReply = nil
                            captureLogger.info("PacketLogger live stream ready")
                            ready(true, nil)
                        }
                        self.consume(data)
                    }
                }
                process.terminationHandler = { [weak self] ended in
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.parseQueue.async {
                        guard let self else { return }
                        stdout.fileHandleForReading.readabilityHandler = nil
                        self.finishPendingRecord()
                        guard self.packetLogger === ended else { return }
                        self.packetLogger = nil
                        if let pending = self.pendingStartReply {
                            self.pendingStartReply = nil
                            pending(false, message?.isEmpty == false ? message : "PacketLogger 启动后意外停止")
                            return
                        }
                        self.client?.captureDidStop(
                            message?.isEmpty == false ? message : "PacketLogger 已停止（\(ended.terminationStatus)）"
                        )
                    }
                }
                self.pendingStartReply = reply
                try process.run()
                self.packetLogger = process
                captureLogger.info("PacketLogger live PTY started")
                self.parseQueue.asyncAfter(deadline: .now() + 2.0) { [weak self, weak process] in
                    guard let self, let process,
                          self.packetLogger === process,
                          let pending = self.pendingStartReply else { return }
                    self.pendingStartReply = nil
                    Self.terminateProcessTree(rootPID: process.processIdentifier)
                    self.packetLogger = nil
                    pending(false, "PacketLogger 实时数据启动超时")
                }
            } catch {
                self.pendingStartReply = nil
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopCapture(reply: @escaping () -> Void) {
        parseQueue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingStartReply {
                self.pendingStartReply = nil
                pending(false, "麦克风采集已取消")
            }
            if let process = self.packetLogger, process.isRunning {
                Self.terminateProcessTree(rootPID: process.processIdentifier)
            }
            self.packetLogger = nil
            self.finishPendingRecord()
            self.pendingOutput.removeAll(keepingCapacity: true)
            self.pendingRecord = nil
            let summary = "bytes=\(self.receivedByteCount) lines=\(self.receivedLineCount) att=\(self.receivedATTCount) activationWrites=\(self.activationWriteCount) handle23=\(self.handle23Count) audioHeaders=\(self.audioHeaderCount) frames=\(self.forwardedFrameCount)"
            captureLogger.info("capture summary \(summary)")
            self.client?.captureDiagnostic("capture summary \(summary)")
            self.receivedByteCount = 0
            self.receivedLineCount = 0
            self.receivedATTCount = 0
            self.handle23Count = 0
            self.audioHeaderCount = 0
            self.forwardedFrameCount = 0
            self.rejectionDiagnosticSent = false
            self.activationWriteCount = 0
            self.keyRecordDiagnosticCount = 0
            self.activationTraceRemaining = 0
            self.postAudioRawDiagnosticCount = 0
            self.awaitingActivationWriteResponse = false
            self.fragmentDiagnosticCount = 0
            self.fragmentedAudioFrame = nil
            reply()
        }
    }

    func connectionInvalidated() {
        stopCapture(reply: {})
    }

    private var client: RemoteMicrophoneCaptureClientProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? RemoteMicrophoneCaptureClientProtocol
    }

    private func consume(_ data: Data) {
        receivedByteCount += data.count
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            let lineData = pendingOutput[..<newline]
            pendingOutput.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            receivedLineCount += 1
            consumeLine(line.trimmingCharacters(in: .newlines))
        }
    }

    /// PacketLogger needs a PTY for live output. Long ATT rows may therefore
    /// be split at the terminal width, with raw hex on continuation lines.
    private func consumeLine(_ line: String) {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        let startsRecord = columns.count >= 7 && columns[0].contains("T")
        if startsRecord {
            finishPendingRecord()
            pendingRecord = line
        } else if pendingRecord != nil {
            pendingRecord?.append(" ")
            pendingRecord?.append(line)
        }
    }

    private func finishPendingRecord() {
        guard let record = pendingRecord else { return }
        pendingRecord = nil
        let columns = record.split(separator: "\t", omittingEmptySubsequences: false)
        let fragmentedResult = consumeFragmentedAudioRecord(columns: columns)
        if record.contains("ATT Receive") { receivedATTCount += 1 }
        if record.contains("Handle:0x0023") { handle23Count += 1 }
        let isActivationWrite = record.contains("ATT Send") &&
            record.contains("Write Request") &&
            (record.contains("Handle:0x001D") || record.contains("Handle:0x0020")) &&
            record.contains("Value: AF")
        if isActivationWrite { activationWriteCount += 1 }
        if isActivationWrite && record.contains("Handle:0x001D") {
            awaitingActivationWriteResponse = true
        } else if awaitingActivationWriteResponse,
                  record.contains("ATT Receive"),
                  record.contains("Write Response") {
            awaitingActivationWriteResponse = false
            client?.microphoneActivationWriteDidComplete()
        }

        // A1962 uses a two-byte notification on 0x0023 for the Siri press
        // transition. Start a fresh, tightly bounded trace here instead of
        // spending the diagnostic budget on the continuous 0x0400 motion
        // notifications that arrive before the button is pressed.
        let isSiriStateNotification = record.contains("ATT Receive") &&
            record.contains("Handle:0x0023") &&
            (record.contains("Value: 0010") ||
             record.contains("Value: 1000") ||
             record.contains("Value: 0000") ||
             record.contains("Value: 1001"))
        if isSiriStateNotification {
            activationTraceRemaining = 12
            if record.contains("Value: 0010") {
                client?.remoteMicrophoneButtonStateDidChange(true)
            } else if record.contains("Value: 1000") {
                client?.remoteMicrophoneButtonStateDidChange(false)
            }
        }
        let isActivationTraceRecord = isSiriStateNotification ||
            isActivationWrite ||
            record.contains("Write Response") ||
            record.contains("Error Response") ||
            record.contains("Prepare Write Request")
        if activationTraceRemaining > 0, isActivationTraceRecord {
            activationTraceRemaining -= 1
            let description = columns.count > 6
                ? String(columns[6].prefix(260))
                : String(record.prefix(260))
            client?.captureDiagnostic("activation trace: \(description)")
        }
        if (isActivationWrite || record.contains("Handle:0x0023")),
           keyRecordDiagnosticCount < 6 {
            keyRecordDiagnosticCount += 1
            let columns = record.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count > 6 {
                client?.captureDiagnostic(
                    "ATT \(String(columns[0])) \(String(columns[1])): \(String(columns[6].prefix(220)))"
                )
            }
        }
        let isAudioHeader = record.contains("Handle:0x0023 - Value: 1010") ||
            record.contains("Handle:0x0023 - Value: 1000") ||
            fragmentedResult.startedFrame
        if isAudioHeader {
            audioHeaderCount += 1
            // Capture a small sample around the first live audio frame only.
            // Resetting this budget for every 15 ms frame floods Baton.log and
            // can itself interfere with real-time audio delivery.
            if forwardedFrameCount == 0, postAudioRawDiagnosticCount == 0 {
                postAudioRawDiagnosticCount = 12
            }
        }
        if postAudioRawDiagnosticCount > 0 {
            postAudioRawDiagnosticCount -= 1
            let raw = columns.count > 7 ? String(columns[7].prefix(360)) : "<no raw column>"
            let kind = columns.count > 1 ? String(columns[1]) : "<unknown>"
            client?.captureDiagnostic("raw fragment kind=\(kind) columns=\(columns.count) bytes=\(raw)")
        }

        if fragmentedResult.startedFrame, fragmentedResult.frame == nil {
            return
        }

        guard let frame = fragmentedResult.frame ?? Self.extractFrame(from: record) else {
            if isAudioHeader {
                let rawTokenCount = columns.count > 7 ? columns[7].split(separator: " ").count : 0
                captureLogger.error("A1962 audio row rejected columns=\(columns.count) rawTokens=\(rawTokenCount)")
                if !rejectionDiagnosticSent {
                    rejectionDiagnosticSent = true
                    client?.captureDiagnostic(
                        "audio row rejected columns=\(columns.count) rawTokens=\(rawTokenCount)"
                    )
                }
            }
            return
        }
        forwardedFrameCount += 1
        if forwardedFrameCount == 1 {
            captureLogger.info("first A1962 Opus frame seq=\(frame.sequence)")
        }
        client?.receiveOpusPacket(frame.packet, sequence: frame.sequence)
    }

    /// PacketLogger's live `itpnahdsr` stream exposes long notifications before
    /// its ATT decoder has reassembled them: an `L2CAP Receive` record contains
    /// the ATT header and the beginning of the Opus packet, followed by one or
    /// more `ACL Receive` continuation records. Offline conversion emits the
    /// same notification as one complete ATT row, so both forms must be
    /// supported here.
    private func consumeFragmentedAudioRecord(
        columns: [Substring]
    ) -> (frame: (packet: Data, sequence: UInt16)?, startedFrame: Bool) {
        guard columns.count >= 8 else { return (nil, false) }
        let kind = columns[1]
        let raw = Self.rawBytes(from: columns[7])
        guard raw.count >= 4 else { return (nil, false) }

        if kind == "L2CAP Receive",
           let offset = Self.attNotificationOffset(in: raw) {
            let valueStart = offset + 3
            guard raw.count >= valueStart + 8,
                  raw[valueStart] == 0x10,
                  raw[valueStart + 1] == 0x10 || raw[valueStart + 1] == 0x00,
                  raw[valueStart + 7] == 0xB8 else {
                return (nil, false)
            }

            let opusLength = Int(raw[valueStart + 6])
            let expectedByteCount = valueStart + 7 + opusLength
            guard opusLength > 0, expectedByteCount <= valueStart + 262 else {
                fragmentedAudioFrame = nil
                return (nil, false)
            }

            if raw.count >= expectedByteCount {
                fragmentedAudioFrame = nil
                return (Self.extractFrame(fromRaw: raw), true)
            }

            fragmentedAudioFrame = FragmentedAudioFrame(
                bytes: raw,
                expectedByteCount: expectedByteCount,
                connectionHandle: Self.connectionHandle(in: raw)
            )
            if fragmentDiagnosticCount < 8 {
                fragmentDiagnosticCount += 1
                captureLogger.info(
                    "audio fragment start bytes=\(raw.count) expected=\(expectedByteCount) handle=\(Self.connectionHandle(in: raw))"
                )
            }
            return (nil, true)
        }

        guard kind == "ACL Receive", var pending = fragmentedAudioFrame else {
            return (nil, false)
        }

        let incomingHandle = Self.connectionHandle(in: raw)
        guard incomingHandle == pending.connectionHandle else {
            if fragmentDiagnosticCount < 8 {
                fragmentDiagnosticCount += 1
                captureLogger.error(
                    "audio continuation handle mismatch incoming=\(incomingHandle) expected=\(pending.connectionHandle)"
                )
            }
            return (nil, false)
        }

        // Strip the four-byte HCI ACL header. PacketLogger gives every
        // continuation its own header, while the L2CAP payload is contiguous.
        pending.bytes.append(contentsOf: raw.dropFirst(4))
        if pending.bytes.count < pending.expectedByteCount {
            fragmentedAudioFrame = pending
            if fragmentDiagnosticCount < 8 {
                fragmentDiagnosticCount += 1
                captureLogger.info(
                    "audio continuation bytes=\(pending.bytes.count) expected=\(pending.expectedByteCount)"
                )
            }
            return (nil, false)
        }

        fragmentedAudioFrame = nil
        let frame = Self.extractFrame(fromRaw: pending.bytes)
        if fragmentDiagnosticCount < 8 {
            fragmentDiagnosticCount += 1
            captureLogger.info(
                "audio reassembly complete bytes=\(pending.bytes.count) decoded=\(frame != nil)"
            )
        }
        return (frame, false)
    }

    private static func extractFrame(from line: String) -> (packet: Data, sequence: UInt16)? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 8,
              columns[1] == "ATT Receive",
              columns[6].contains("Handle Value Notification"),
              columns[6].contains("Handle:0x0023") else { return nil }

        return extractFrame(fromRaw: rawBytes(from: columns[7]))
    }

    private static func extractFrame(fromRaw raw: [UInt8]) -> (packet: Data, sequence: UInt16)? {
        guard raw.count >= 19,
              let offset = attNotificationOffset(in: raw) else { return nil }
        let start = offset + 3
        guard raw.count >= start + 8 else { return nil }
        let value = Array(raw[start...])
        guard value[0] == 0x10,
              value[1] == 0x10 || value[1] == 0x00,
              value[7] == 0xB8 else { return nil }
        let length = Int(value[6])
        guard length > 0, value.count >= 7 + length else { return nil }
        let sequence = UInt16(value[4]) | (UInt16(value[5]) << 8)
        return (Data(value[7..<(7 + length)]), sequence)
    }

    private static func rawBytes(from column: Substring) -> [UInt8] {
        column.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    private static func attNotificationOffset(in raw: [UInt8]) -> Int? {
        raw.indices.first { index in
            index + 2 < raw.count && raw[index] == 0x1B &&
                raw[index + 1] == 0x23 && raw[index + 2] == 0x00
        }
    }

    private static func connectionHandle(in raw: [UInt8]) -> UInt16 {
        guard raw.count >= 2 else { return 0 }
        // The packet-boundary and broadcast flags occupy the high nibble.
        return UInt16(raw[0]) | (UInt16(raw[1] & 0x0F) << 8)
    }

    private static func validatedPacketLoggerURL() throws -> URL {
        let candidates = [
            "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
            "/Applications/Additional Tools/PacketLogger.app/Contents/Resources/packetlogger"
        ]
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw NSError(domain: batonMicrophoneMachService, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 PacketLogger，请安装 Bluetooth Logging for macOS"
            ])
        }

        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw NSError(domain: batonMicrophoneMachService, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法验证 PacketLogger"
            ])
        }
        var requirement: SecRequirement?
        let requirementText = "identifier \"com.apple.packetlogger\" and anchor apple" as CFString
        guard SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else {
            throw NSError(domain: batonMicrophoneMachService, code: 3, userInfo: [
                NSLocalizedDescriptionKey: "PacketLogger 签名不是 Apple 官方版本"
            ])
        }
        return URL(fileURLWithPath: path)
    }

    /// `script` and PacketLogger use separate process groups. Terminating only
    /// the Process object otherwise leaves PacketLogger capturing indefinitely.
    private static func terminateProcessTree(rootPID: pid_t) {
        let children = childPIDs(of: rootPID)
        let descendants = children.flatMap { childPIDs(of: $0) + [$0] }
        let targets = descendants.reversed().filter { $0 > 1 } + (rootPID > 1 ? [rootPID] : [])
        for pid in targets {
            _ = Darwin.kill(pid, SIGTERM)
        }
        // PacketLogger's converter can remain attached to its PTY after TERM.
        // Give it a brief graceful window, then guarantee that a relaunched
        // Baton cannot leave duplicate full-HCI capture processes behind.
        usleep(150_000)
        for pid in targets where Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let byteCount = proc_listchildpids(parent, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var result = Array(repeating: pid_t(0), count: capacity)
        let written = result.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        return Array(result.prefix(Int(written) / MemoryLayout<pid_t>.stride)).filter { $0 > 1 }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.isBaton(connection.processIdentifier) else { return false }
        let service = CaptureService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: RemoteMicrophoneCaptureServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: RemoteMicrophoneCaptureClientProtocol.self)
        connection.invalidationHandler = {
            service.connectionInvalidated()
        }
        connection.resume()
        return true
    }

    private static func isBaton(_ pid: pid_t) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest,
              SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
              let client = signingIdentity(of: guest),
              client.identifier == "com.baton.app",
              !client.team.isEmpty,
              let ownCode = SecCodeCopySelfCode(),
              let helper = signingIdentity(of: ownCode),
              client.team == helper.team else { return false }
        return true
    }

    private static func signingIdentity(of code: SecCode) -> (identifier: String, team: String)? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(
                  staticCode,
                  SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
                  &information
              ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String,
              let team = values[kSecCodeInfoTeamIdentifier] as? String else { return nil }
        return (identifier, team)
    }
}

private func SecCodeCopySelfCode() -> SecCode? {
    var code: SecCode?
    return SecCodeCopySelf([], &code) == errSecSuccess ? code : nil
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: batonMicrophoneMachService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

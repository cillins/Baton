//
//  main.swift
//  mic-spike — Siri Remote microphone capture verification
//
//  Modes:
//    decode <frames.txt> <out.wav>          Decode [len][Opus…] hex frames
//    parse <capture.pklg|capture.txt> <frames.txt>
//                                            Extract A1962 Opus frames
//    decode-pklg <capture.pklg> <out.wav>   Extract and decode in one step
//    stream <out.wav>                       Decode PacketLogger TSV from stdin
//


import Foundation
import Darwin

// MARK: - Opus decoder (libopus via bridging header)

final class OpusDecoder {
    private var dec: OpaquePointer?
    private let maxSamples = 1920 // 120ms @16kHz ceiling

    init?(sampleRate: Int32 = 16000, channels: Int32 = 1) {
        var err: Int32 = 0
        dec = opus_decoder_create(sampleRate, channels, &err)
        guard err == OPUS_OK, dec != nil else { return nil }
    }

    deinit { if let d = dec { opus_decoder_destroy(d) } }

    func decode(_ packet: [UInt8]) -> [Int16]? {
        guard let d = dec else { return nil }
        var pcm = [Int16](repeating: 0, count: maxSamples)
        let n = packet.withUnsafeBufferPointer { src -> Int32 in
            pcm.withUnsafeMutableBufferPointer { dst -> Int32 in
                opus_decode(d, src.baseAddress, opus_int32(packet.count),
                            dst.baseAddress!, Int32(maxSamples), 0)
            }
        }
        guard n >= 0 else { return nil }
        return Array(pcm.prefix(Int(n)))
    }
}

// MARK: - WAV writer (16kHz mono 16-bit PCM)

func writeWav(_ pcm: [Int16], to path: String) throws {
    let dataSize = UInt32(pcm.count * 2)
    var out = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }
    out.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    u32(36 + dataSize)
    out.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    out.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
    u32(16)
    u16(1)
    u16(1)
    u32(16000)
    u32(32000)
    u16(2)
    u16(16)
    out.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    u32(dataSize)
    for s in pcm { var x = s.littleEndian; out.append(Data(bytes: &x, count: 2)) }
    try out.write(to: URL(fileURLWithPath: path))
}

// MARK: - Frame files

func parseHexBytes(_ line: Substring) -> [UInt8]? {
    let parts = line.split(separator: " ")
    guard !parts.isEmpty else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(parts.count)
    for part in parts {
        guard let byte = UInt8(part, radix: 16) else { return nil }
        bytes.append(byte)
    }
    return bytes
}

/// Frame layout is `[Opus length][Opus packet]`.
func frameToPacket(_ bytes: [UInt8]) -> [UInt8]? {
    guard bytes.count > 1 else { return nil }
    let length = Int(bytes[0])
    guard length > 0, bytes.count >= 1 + length else { return nil }
    return Array(bytes[1..<(1 + length)])
}

func readFrameFile(_ path: String) throws -> [[UInt8]] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        guard let bytes = parseHexBytes(line) else { return nil }
        return frameToPacket(bytes)
    }
}

func writeFrameFile(_ frames: [CapturedFrame], to path: String) throws {
    let text = frames.map { frame in
        ([UInt8(frame.packet.count)] + frame.packet)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }.joined(separator: "\n") + "\n"
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - PacketLogger extraction

struct CapturedFrame {
    let packet: [UInt8]
    let sequence: UInt16
    let timestamp: Date?
}

enum SpikeError: LocalizedError {
    case packetLoggerNotFound
    case packetLoggerFailed(String)
    case invalidUTF8
    case noAudioFrames

    var errorDescription: String? {
        switch self {
        case .packetLoggerNotFound:
            return "PacketLogger CLI not found. Install Bluetooth Logging for macOS and PacketLogger.app."
        case .packetLoggerFailed(let message):
            return "PacketLogger conversion failed: \(message)"
        case .invalidUTF8:
            return "PacketLogger output is not valid UTF-8 text."
        case .noAudioFrames:
            return "No A1962 microphone frames found (ATT handle 0x0023, 0x10xx payload, Opus marker 0xB8)."
        }
    }
}

func packetLoggerExecutable() -> String? {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [
        environment["PACKETLOGGER_CLI"],
        "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
        "/Applications/Additional Tools/PacketLogger.app/Contents/Resources/packetlogger"
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func convertPKLGToText(_ path: String) throws -> String {
    guard let executable = packetLoggerExecutable() else {
        throw SpikeError.packetLoggerNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["convert", "--input", path, "--stdout", "--format", "itpnahdsr"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let message = String(data: errorOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SpikeError.packetLoggerFailed(message?.isEmpty == false ? message! : "exit \(process.terminationStatus)")
    }
    guard let text = String(data: output, encoding: .utf8) else {
        throw SpikeError.invalidUTF8
    }
    return text
}

private let packetLoggerDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func extractCapturedFrames(from packetLoggerText: String) -> [CapturedFrame] {
    var result = [CapturedFrame]()

    for line in packetLoggerText.split(separator: "\n") {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 8,
              columns[1] == "ATT Receive",
              columns[6].contains("Handle Value Notification"),
              columns[6].contains("Handle:0x0023") else { continue }

        let raw = columns[7].split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard raw.count >= 19 else { continue }

        // PacketLogger's raw ATT record starts with HCI/L2CAP headers. Locate the
        // notification opcode and little-endian attribute handle, then parse value.
        guard let attOffset = raw.indices.first(where: { index in
            index + 2 < raw.count &&
                raw[index] == 0x1B && raw[index + 1] == 0x23 && raw[index + 2] == 0x00
        }) else { continue }

        let valueStart = attOffset + 3
        guard raw.count >= valueStart + 8 else { continue }
        let value = Array(raw[valueStart...])

        // A1962 audio notifications share handle 0x0023 with motion data.
        // Audio begins with 0x10xx; byte 6 is Opus length and byte 7 is the
        // first Opus byte (0xB8 for the observed 16kHz mono stream).
        guard value[0] == 0x10,
              value[1] == 0x10 || value[1] == 0x00,
              value[7] == 0xB8 else { continue }

        let opusLength = Int(value[6])
        guard opusLength > 0, value.count >= 7 + opusLength else { continue }
        let packet = Array(value[7..<(7 + opusLength)])
        let sequence = UInt16(value[4]) | (UInt16(value[5]) << 8)
        let timestamp = packetLoggerDateFormatter.date(from: String(columns[0]))
        result.append(CapturedFrame(packet: packet, sequence: sequence, timestamp: timestamp))
    }

    return result
}

func loadCapture(_ path: String) throws -> [CapturedFrame] {
    let text: String
    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pklg" {
        text = try convertPKLGToText(path)
    } else {
        text = try String(contentsOfFile: path, encoding: .utf8)
    }
    let frames = extractCapturedFrames(from: text)
    guard !frames.isEmpty else { throw SpikeError.noAudioFrames }
    return frames
}

func printCaptureStats(_ frames: [CapturedFrame]) {
    var sessions = [[CapturedFrame]]()
    var current = [CapturedFrame]()

    for frame in frames {
        if let previous = current.last,
           let previousTime = previous.timestamp,
           let time = frame.timestamp,
           time.timeIntervalSince(previousTime) > 0.12 {
            sessions.append(current)
            current = []
        }
        current.append(frame)
    }
    if !current.isEmpty { sessions.append(current) }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("extracted \(frames.count) Opus frames in \(sessions.count) session(s)")

    for (index, session) in sessions.enumerated() {
        let sequenceGaps = zip(session, session.dropFirst()).filter { previous, next in
            next.sequence != previous.sequence &+ 1
        }.count
        let duration = Double(session.count) * 0.020
        let timeRange: String
        if let start = session.first?.timestamp, let end = session.last?.timestamp {
            timeRange = " [\(formatter.string(from: start)) … \(formatter.string(from: end))]"
        } else {
            timeRange = ""
        }
        print("  session \(index + 1): \(session.count) frames, \(String(format: "%.2f", duration))s, sequence gaps: \(sequenceGaps)\(timeRange)")
    }
}

// MARK: - Decode

func decodePackets(_ packets: [[UInt8]], outPath: String) throws {
    guard let decoder = OpusDecoder() else {
        throw SpikeError.packetLoggerFailed("opus_decoder_create failed")
    }
    var pcm = [Int16]()
    var decodedCount = 0
    var failedCount = 0

    for packet in packets {
        if let decoded = decoder.decode(packet) {
            pcm.append(contentsOf: decoded)
            decodedCount += 1
        } else {
            failedCount += 1
        }
    }

    try writeWav(pcm, to: outPath)
    let seconds = Double(pcm.count) / 16000.0
    print("decoded \(decodedCount) frames (\(failedCount) failed) → \(pcm.count) samples ≈ \(String(format: "%.2f", seconds))s → \(outPath)")
}

func decodePacketLoggerStream(outPath: String) throws {
    guard let decoder = OpusDecoder() else {
        throw SpikeError.packetLoggerFailed("opus_decoder_create failed")
    }

    // In a shell pipeline, Ctrl-C stops PacketLogger and closes stdin. Ignoring
    // SIGINT here lets mic-spike finish the WAV header before it exits.
    signal(SIGINT, SIG_IGN)

    var captured = [CapturedFrame]()
    var pcm = [Int16]()
    var failedCount = 0

    while let line = readLine() {
        for frame in extractCapturedFrames(from: line) {
            captured.append(frame)
            if let decoded = decoder.decode(frame.packet) {
                pcm.append(contentsOf: decoded)
            } else {
                failedCount += 1
            }
            if captured.count.isMultiple(of: 50) {
                let seconds = Double(pcm.count) / 16000.0
                FileHandle.standardError.write(
                    "\rcaptured \(captured.count) frames ≈ \(String(format: "%.2f", seconds))s"
                        .data(using: .utf8)!
                )
            }
        }
    }

    FileHandle.standardError.write("\n".data(using: .utf8)!)
    guard !captured.isEmpty else { throw SpikeError.noAudioFrames }
    try writeWav(pcm, to: outPath)
    printCaptureStats(captured)
    let seconds = Double(pcm.count) / 16000.0
    print("decoded \(captured.count - failedCount) frames (\(failedCount) failed) → \(pcm.count) samples ≈ \(String(format: "%.2f", seconds))s → \(outPath)")
}

// MARK: - Main

func usage() {
    print("""
    usage:
      mic-spike decode <frames.txt> <out.wav>
      mic-spike parse <capture.pklg|capture.txt> <frames.txt>
      mic-spike decode-pklg <capture.pklg> <out.wav>
      mic-spike stream <out.wav>
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    usage()
    exit(2)
}

do {
    switch args[1] {
    case "decode":
        guard args.count == 4 else { usage(); exit(2) }
        try decodePackets(readFrameFile(args[2]), outPath: args[3])

    case "parse":
        guard args.count == 4 else { usage(); exit(2) }
        let frames = try loadCapture(args[2])
        try writeFrameFile(frames, to: args[3])
        printCaptureStats(frames)
        print("wrote frames → \(args[3])")

    case "decode-pklg":
        guard args.count == 4 else { usage(); exit(2) }
        let frames = try loadCapture(args[2])
        printCaptureStats(frames)
        try decodePackets(frames.map(\.packet), outPath: args[3])

    case "stream":
        guard args.count == 3 else { usage(); exit(2) }
        try decodePacketLoggerStream(outPath: args[2])

    default:
        usage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

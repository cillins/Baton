//
//  main.swift
//  mic-spike — Siri Remote mic capture module verification
//
//  Modes:
//    decode <frames.txt> <out.wav>   Decode [len][0xB8][opus…] hex frames to WAV
//    parse  <capture.txt>            Extract frames from packetlogger text dump → frames.txt
//    stream                          Read packetlogger stdout on stdin live → decoded.wav
//

import Foundation

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

    /// Decode one Opus packet → 16-bit PCM samples.
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
    out.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
    u32(36 + dataSize)
    out.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
    out.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt␣
    u32(16)          // chunk size
    u16(1)           // PCM
    u16(1)           // mono
    u32(16000)       // sample rate
    u32(32000)       // byte rate
    u16(2)           // block align
    u16(16)          // bits
    out.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
    u32(dataSize)
    for s in pcm { var x = s.littleEndian; out.append(Data(bytes: &x, count: 2)) }
    try out.write(to: URL(fileURLWithPath: path))
}

// MARK: - frames.txt parsing: one frame per line, "[len] B8 [opus…]" hex

func parseHexBytes(_ line: String) -> [UInt8]? {
    let parts = line.split(separator: " ")
    guard !parts.isEmpty else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(parts.count)
    for p in parts {
        guard let b = UInt8(p, radix: 16) else { return nil }
        bytes.append(b)
    }
    return bytes
}

/// frames.txt line → Opus packet (first byte = payload length, then payload).
func frameToPacket(_ bytes: [UInt8]) -> [UInt8]? {
    guard bytes.count > 1 else { return nil }
    let len = Int(bytes[0])
    guard len > 0, bytes.count >= 1 + len else { return nil }
    return Array(bytes[1..<(1 + len)])
}

// MARK: - decode mode

func decodeFrames(framesPath: String, outPath: String) {
    guard let text = try? String(contentsOfFile: framesPath, encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(framesPath)\n".data(using: .utf8)!)
        exit(1)
    }
    guard let dec = OpusDecoder() else {
        FileHandle.standardError.write("opus_decoder_create failed\n".data(using: .utf8)!)
        exit(1)
    }
    var pcm = [Int16]()
    var ok = 0, bad = 0
    for line in text.split(separator: "\n") {
        let s = String(line)
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty,
              let bytes = parseHexBytes(s),
              let packet = frameToPacket(bytes) else { continue }
        if let decoded = dec.decode(packet) {
            pcm.append(contentsOf: decoded)
            ok += 1
        } else {
            bad += 1
        }
    }
    do {
        try writeWav(pcm, to: outPath)
        let seconds = Double(pcm.count) / 16000.0
        print("decoded \(ok) frames (\(bad) failed) → \(pcm.count) samples ≈ \(String(format: "%.2f", seconds))s → \(outPath)")
    } catch {
        FileHandle.standardError.write("wav write failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: mic-spike decode <frames.txt> <out.wav>")
    exit(2)
}
switch args[1] {
case "decode":
    guard args.count == 4 else { print("usage: mic-spike decode <frames.txt> <out.wav>"); exit(2) }
    decodeFrames(framesPath: args[2], outPath: args[3])
default:
    print("unknown mode: \(args[1])")
    exit(2)
}

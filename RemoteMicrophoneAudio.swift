//
//  RemoteMicrophoneAudio.swift
//  Baton
//
//  Decodes A1962 Opus frames and feeds the private output side of
//  Baton Remote Microphone. CoreAudio exposes the looped-back input side
//  to conferencing and recording applications.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum RemoteMicrophoneAudioError: LocalizedError {
    case opusUnavailable
    case opusInitialization(Int32)
    case virtualDeviceMissing
    case audioUnitUnavailable
    case audioUnitConfiguration(OSStatus)
    case engineStart(String)

    var errorDescription: String? {
        switch self {
        case .opusUnavailable:
            return "找不到 Opus 解码库"
        case .opusInitialization(let code):
            return "Opus 解码器初始化失败（\(code)）"
        case .virtualDeviceMissing:
            return "尚未安装 Baton Remote Microphone"
        case .audioUnitUnavailable:
            return "无法创建虚拟麦克风音频输出"
        case .audioUnitConfiguration(let status):
            return "无法选择虚拟麦克风设备（\(status)）"
        case .engineStart(let message):
            return "无法启动虚拟麦克风：\(message)"
        }
    }
}

/// Runtime-loaded libopus keeps the normal Baton build independent of Homebrew.
/// Distribution packaging places the BSD-licensed dylib in Contents/Frameworks;
/// developer builds can use a local Homebrew installation.
final class RemoteOpusDecoder {
    private typealias CreateFn = @convention(c) (
        Int32, Int32, UnsafeMutablePointer<Int32>?
    ) -> OpaquePointer?
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    private typealias DecodeFn = @convention(c) (
        OpaquePointer?, UnsafePointer<UInt8>?, Int32,
        UnsafeMutablePointer<Int16>?, Int32, Int32
    ) -> Int32

    private let library: UnsafeMutableRawPointer
    private let destroyFn: DestroyFn
    private let decodeFn: DecodeFn
    private var decoder: OpaquePointer?
    private let maximumSamples = 1920

    init() throws {
        let bundled = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libopus.0.dylib").path
        let candidates = [
            bundled,
            "/opt/homebrew/opt/opus/lib/libopus.0.dylib",
            "/usr/local/opt/opus/lib/libopus.0.dylib"
        ].compactMap { $0 }

        guard let handle = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first,
              let createSymbol = dlsym(handle, "opus_decoder_create"),
              let destroySymbol = dlsym(handle, "opus_decoder_destroy"),
              let decodeSymbol = dlsym(handle, "opus_decode") else {
            throw RemoteMicrophoneAudioError.opusUnavailable
        }
        library = handle
        let createFn = unsafeBitCast(createSymbol, to: CreateFn.self)
        destroyFn = unsafeBitCast(destroySymbol, to: DestroyFn.self)
        decodeFn = unsafeBitCast(decodeSymbol, to: DecodeFn.self)

        var error: Int32 = 0
        decoder = createFn(16_000, 1, &error)
        guard error == 0, decoder != nil else {
            dlclose(handle)
            throw RemoteMicrophoneAudioError.opusInitialization(error)
        }
    }

    deinit {
        destroyFn(decoder)
        dlclose(library)
    }

    func decode(_ packet: Data) -> [Int16]? {
        guard !packet.isEmpty else { return nil }
        var pcm = [Int16](repeating: 0, count: maximumSamples)
        let count = packet.withUnsafeBytes { encoded in
            pcm.withUnsafeMutableBufferPointer { output in
                decodeFn(
                    decoder,
                    encoded.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.count),
                    output.baseAddress,
                    Int32(maximumSamples),
                    0
                )
            }
        }
        guard count > 0 else { return nil }
        return Array(pcm.prefix(Int(count)))
    }
}

final class VirtualMicrophoneFeeder {
    static let deviceUID = "com.baton.audio.RemoteMicrophone.device"

    private let queue = DispatchQueue(label: "com.baton.virtual-microphone.audio")
    private var decoder: RemoteOpusDecoder?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var sourceFormat: AVAudioFormat?
    private(set) var isRunning = false

    func start() throws {
        if isRunning { return }
        let device = try Self.findDeviceID()
        let decoder = try RemoteOpusDecoder()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw RemoteMicrophoneAudioError.audioUnitUnavailable }

        guard let outputUnit = engine.outputNode.audioUnit else {
            throw RemoteMicrophoneAudioError.audioUnitUnavailable
        }
        var selectedDevice = device
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RemoteMicrophoneAudioError.audioUnitConfiguration(status)
        }

        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RemoteMicrophoneAudioError.engineStart(error.localizedDescription)
        }
        player.play()

        self.decoder = decoder
        self.engine = engine
        self.player = player
        self.sourceFormat = sourceFormat
        isRunning = true
        rmDebug("🎙 virtual microphone feeder started device=\(device)")
    }

    func stop() {
        queue.sync {
            player?.stop()
            engine?.stop()
            player = nil
            engine = nil
            decoder = nil
            sourceFormat = nil
            isRunning = false
        }
        rmDebug("🎙 virtual microphone feeder stopped")
    }

    func enqueue(opus packet: Data, sequence: UInt16) {
        queue.async { [weak self] in
            guard let self,
                  self.isRunning,
                  let pcm = self.decoder?.decode(packet),
                  let format = self.sourceFormat,
                  let player = self.player,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(pcm.count)
                  ),
                  let channel = buffer.floatChannelData?[0] else { return }

            buffer.frameLength = AVAudioFrameCount(pcm.count)
            for index in pcm.indices {
                channel[index] = Float(pcm[index]) / Float(Int16.max)
            }
            player.scheduleBuffer(buffer)
            rmDebug("🎙 queued Opus seq=\(sequence) samples=\(pcm.count)")
        }
    }

    static var isDriverInstalled: Bool {
        (try? findDeviceID()) != nil
    }

    private static func findDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { throw RemoteMicrophoneAudioError.virtualDeviceMissing }

        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { throw RemoteMicrophoneAudioError.virtualDeviceMissing }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidReference: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(
                device, &uidAddress, 0, nil, &uidSize, &uidReference
            ) == noErr,
               let uid = uidReference?.takeUnretainedValue(),
               uid as String == deviceUID {
                return device
            }
        }
        throw RemoteMicrophoneAudioError.virtualDeviceMissing
    }
}

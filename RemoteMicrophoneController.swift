//
//  RemoteMicrophoneController.swift
//  Baton
//

import AppKit
import Foundation
import Security
import ServiceManagement

final class RemoteMicrophoneController: NSObject, RemoteMicrophoneCaptureClientProtocol {
    static let shared = RemoteMicrophoneController()
    enum ComponentStatus: String {
        case unsupported, notRegistered, requiresApproval, enabled, notFound
    }

    enum PacketLoggerStatus {
        case ready, missing, invalidSignature
    }

    static let packetLoggerDownloadURL = URL(string: "https://developer.apple.com/bluetooth/")!
    private static let packetLoggerExecutablePaths = [
        "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
        "/Applications/Additional Tools/PacketLogger.app/Contents/Resources/packetlogger"
    ]

    private let feeder = VirtualMicrophoneFeeder()
    private var connection: NSXPCConnection?
    private var isStarting = false
    private var captureGeneration: UInt64 = 0
    private var activationSecondStageSent = false
    private(set) var isCapturing = false
    var onStatusChange: ((String) -> Void)?
    var onActivationWriteComplete: (() -> Void)?
    var onCapturedButtonStateChange: ((Bool) -> Void)?
    private var didLogFirstReceivedFrame = false

    var componentStatus: ComponentStatus {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.daemon(plistName: "com.baton.miccapture.plist").status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    static var packetLoggerStatus: PacketLoggerStatus {
        guard let executableURL = packetLoggerExecutableURL else { return .missing }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return .invalidSignature }
        var requirement: SecRequirement?
        let text = "identifier \"com.apple.packetlogger\" and anchor apple" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else {
            return .invalidSignature
        }
        return .ready
    }

    static var packetLoggerAppURL: URL? {
        guard let executableURL = packetLoggerExecutableURL else { return nil }
        var url = executableURL
        while url.pathExtension != "app", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url.pathExtension == "app" ? url : nil
    }

    private static var packetLoggerExecutableURL: URL? {
        packetLoggerExecutablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }

    /// Re-submit the launch daemon when its executable/protocol changes. The
    /// system keeps an already-running helper mapped from the previous app
    /// version, so merely replacing Baton.app is not enough to load a fix.
    func migrateRegisteredHelperIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        let migrationKey = "microphoneCaptureHelperSchema"
        let currentSchema = 19
        guard UserDefaults.standard.integer(forKey: migrationKey) < currentSchema else { return }

        let service = SMAppService.daemon(plistName: "com.baton.miccapture.plist")
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                // launchd rejects an immediate re-register while the previous
                // daemon is still settling. Use the same delayed path as the
                // explicit "restart component" action.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    do {
                        try service.register()
                        UserDefaults.standard.set(currentSchema, forKey: migrationKey)
                        rmDebug("🎙 capture helper re-submitted for schema \(currentSchema)")
                        self.onStatusChange?(self.componentStatus.rawValue)
                    } catch {
                        rmDebug("🎙 capture helper delayed migration failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            // A fresh install keeps microphone capture optional. Merely
            // launching Baton must not register a privileged background item;
            // registration happens only from the explicit settings action.
            UserDefaults.standard.set(currentSchema, forKey: migrationKey)
        } catch {
            rmDebug("🎙 capture helper migration failed: \(error.localizedDescription)")
        }
    }

    func registerCaptureHelper() throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: batonMicrophoneMachService, code: 10, userInfo: [
                NSLocalizedDescriptionKey: "遥控器麦克风需要 macOS 13 或更高版本"
            ])
        }
        guard Self.packetLoggerStatus == .ready else {
            throw NSError(domain: batonMicrophoneMachService, code: 13, userInfo: [
                NSLocalizedDescriptionKey: "请先安装 Apple Bluetooth Logging for macOS / PacketLogger"
            ])
        }
        try SMAppService.daemon(plistName: "com.baton.miccapture.plist").register()
        if componentStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        onStatusChange?(componentStatus.rawValue)
    }

    func unregisterCaptureHelper() throws {
        stop()
        guard #available(macOS 13.0, *) else { return }
        try SMAppService.daemon(plistName: "com.baton.miccapture.plist").unregister()
        onStatusChange?(componentStatus.rawValue)
    }

    func restartCaptureHelper(completion: @escaping (Result<Void, Error>) -> Void) {
        guard #available(macOS 13.0, *) else {
            completion(.success(()))
            return
        }
        stop()
        let service = SMAppService.daemon(plistName: "com.baton.miccapture.plist")
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            completion(.failure(error))
            return
        }
        // ServiceManagement needs a short settling interval after removing a
        // running system daemon; immediate unregister/register returns EPERM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                self.onStatusChange?(self.componentStatus.rawValue)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func openDriverInstaller() throws {
        guard let url = Bundle.main.url(
            forResource: "Install Baton Remote Microphone",
            withExtension: "command"
        ) else {
            throw NSError(domain: batonMicrophoneMachService, code: 11, userInfo: [
                NSLocalizedDescriptionKey: "安装程序未包含在 Baton.app 中"
            ])
        }
        NSWorkspace.shared.open(url)
    }

    func openDriverUninstaller() throws {
        guard let url = Bundle.main.url(
            forResource: "Uninstall Baton Remote Microphone",
            withExtension: "command"
        ) else {
            throw NSError(domain: batonMicrophoneMachService, code: 12, userInfo: [
                NSLocalizedDescriptionKey: "卸载程序未包含在 Baton.app 中"
            ])
        }
        NSWorkspace.shared.open(url)
    }

    func start(startFeeder: Bool = true, completion: ((Bool) -> Void)? = nil) {
        activationSecondStageSent = false
        guard Self.packetLoggerStatus == .ready else {
            onStatusChange?("packetLoggerMissing")
            completion?(false)
            return
        }
        if startFeeder {
            do {
                try feeder.start()
            } catch {
                rmDebug("🎙 cannot start feeder: \(error.localizedDescription)")
                onStatusChange?(error.localizedDescription)
                completion?(false)
                return
            }
        }
        if isCapturing {
            completion?(true)
            return
        }
        // Duplicate HID transitions must not open overlapping privileged
        // captures while the asynchronous helper reply is still pending.
        guard !isStarting else { return }
        isStarting = true
        captureGeneration &+= 1
        let generation = captureGeneration

        let connection = NSXPCConnection(machServiceName: batonMicrophoneMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: RemoteMicrophoneCaptureServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: RemoteMicrophoneCaptureClientProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.isStarting = false
                self.isCapturing = false
                self.feeder.stop()
                self.connection = nil
                self.onStatusChange?("captureDisconnected")
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        self.connection = connection

        guard let service = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            rmDebug("🎙 helper connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.captureDidStop(error.localizedDescription)
                completion?(false)
            }
        }) as? RemoteMicrophoneCaptureServiceProtocol else {
            captureDidStop("无法连接遥控器麦克风组件")
            completion?(false)
            return
        }
        service.startCapture { [weak self] success, message in
            DispatchQueue.main.async {
                guard let self,
                      self.captureGeneration == generation,
                      self.isStarting else {
                    connection.invalidate()
                    return
                }
                self.isStarting = false
                if success {
                    self.isCapturing = true
                    self.onStatusChange?("capturing")
                    rmDebug("🎙 HCI microphone capture started")
                    completion?(true)
                } else {
                    self.captureDidStop(message ?? "遥控器麦克风启动失败")
                    completion?(false)
                }
            }
        }
    }

    func stop() {
        captureGeneration &+= 1
        isStarting = false
        guard let connection else {
            feeder.stop()
            isCapturing = false
            return
        }
        let service = connection.remoteObjectProxyWithErrorHandler { _ in }
            as? RemoteMicrophoneCaptureServiceProtocol
        isCapturing = false
        onStatusChange?("ready")
        guard let service else {
            connection.invalidate()
            self.connection = nil
            feeder.stop()
            return
        }
        // Preserve the XPC channel and feeder until the helper flushes its last
        // PTY record and reports its capture statistics.
        service.stopCapture { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, let connection else { return }
                connection.invalidate()
                if self.connection === connection { self.connection = nil }
                self.feeder.stop()
            }
        }
    }

    /// Attach PacketLogger before Siri-down. On-demand startup misses the
    /// button transition and makes IOHID feature writes intermittent.
    func prewarmCapture() {
        guard componentStatus == .enabled,
              Self.packetLoggerStatus == .ready,
              !isCapturing, !isStarting else { return }
        start(startFeeder: false) { [weak self] ready in
            guard let self, ready else { return }
            self.onStatusChange?("ready")
            rmDebug("🎙 HCI microphone capture prewarmed")
        }
    }

    /// Stop push-to-talk audio but leave PacketLogger attached for the next
    /// press. Full `stop()` remains reserved for component shutdown/restart.
    func endVoiceSession() {
        feeder.stop()
        onStatusChange?(isCapturing ? "ready" : "captureDisconnected")
    }

    func receiveOpusPacket(_ packet: Data, sequence: UInt16) {
        if !didLogFirstReceivedFrame {
            didLogFirstReceivedFrame = true
            rmDebug("🎙 first reconstructed Opus frame seq=\(sequence) bytes=\(packet.count)")
        }
        feeder.enqueue(opus: packet, sequence: sequence)
    }

    func remoteMicrophoneButtonStateDidChange(_ pressed: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onCapturedButtonStateChange?(pressed)
        }
    }

    func microphoneActivationWriteDidComplete() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing,
                  !self.activationSecondStageSent else { return }
            self.activationSecondStageSent = true
            rmDebug("🎙 microphone activation 0x001D acknowledged")
            self.onActivationWriteComplete?()
        }
    }

    func captureDiagnostic(_ message: String) {
        rmDebug("🎙 helper \(message)")
    }

    func captureDidStop(_ error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let error { rmDebug("🎙 capture stopped: \(error)") }
            self.captureGeneration &+= 1
            self.isStarting = false
            self.isCapturing = false
            self.feeder.stop()
            self.connection?.invalidate()
            self.connection = nil
            self.onStatusChange?(error ?? "ready")
        }
    }
}

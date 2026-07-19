//
//  SiriRemoteApp.swift
//  Baton
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var settingsWindow: SettingsWindowController?
    private var bleBatteryMonitor: BleBatteryMonitor?
    private let motionCapture = MotionCapture()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Baton starting...")

        // Bluetooth AVRCP play/pause signals bypass cghidEventTap and reach com.apple.rcd
        // directly, which launches Music.app. Suspend rcd for this session; restored on exit.
        RCDControl.suspend()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)

        // Wire the "打开主窗口…" menu item to show the React-based settings window.
        // Connection-state changes are pushed live to the webview via pushConnectionState.
        settingsWindow = SettingsWindowController(menuBarManager: menuBarManager, remoteDetector: remoteDetector)
        menuBarManager.onOpenSettings = { [weak self] in
            self?.settingsWindow?.show()
        }
        menuBarManager.onConnectionChange = { [weak self] connected in
            let name = self?.remoteDetector?.currentDeviceName
            self?.menuBarManager.currentDeviceName = name
            self?.settingsWindow?.pushConnectionState(connected: connected, deviceName: name)
        }
        menuBarManager.onScrollSpeedChange = { [weak self] speed in
            self?.touchHandler?.scrollScale = speed.scale
        }
        menuBarManager.onTrackpadSensitivityChange = { [weak self] value in
            self?.touchHandler?.cursorScale = CGFloat(value)
        }
        menuBarManager.onAppearanceChange = { [weak self] appearance in
            self?.settingsWindow?.pushAppearance(appearance)
        }

        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )
        remoteInputHandler?.applyGyroSettings(gain: menuBarManager.gyroGain,
                                              minCutoff: menuBarManager.gyroMinCutoff)
        menuBarManager.onGyroSettingsChange = { [weak self] in
            guard let self = self else { return }
            self.remoteInputHandler?.applyGyroSettings(gain: self.menuBarManager.gyroGain,
                                                       minCutoff: self.menuBarManager.gyroMinCutoff)
        }
        motionCapture.onGyro = { [weak remoteInputHandler] x, y, z in
            remoteInputHandler?.handleGyro(x: x, y: y, z: z)
        }
        
        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        touchHandler?.cursorScale = CGFloat(menuBarManager.trackpadSensitivity)
        touchHandler?.onSwipe = { [weak menuBarManager] direction in
            menuBarManager?.executeSwipe(direction)
        }
        touchHandler?.start()
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                let name = self?.remoteDetector?.currentDeviceName
                self?.menuBarManager.currentDeviceName = name
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
                self?.settingsWindow?.pushConnectionState(connected: device != nil, deviceName: name)
                if device != nil {
                    // The remote just came up at the OS level — re-run the BLE
                    // battery retrieve (it stops advertising once connected, so
                    // the startup scan alone would never find it). Retry once
                    // after 2s to cover CoreBluetooth's GATT-visibility lag.
                    self?.bleBatteryMonitor?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.bleBatteryMonitor?.refresh()
                    }
                    // Gen 1 only: start gyro capture (gen 2/3 have no motion hardware).
                    if self?.remoteDetector?.currentGeneration == .gen1, let d = device {
                        self?.motionCapture.attach(d)
                    }
                } else {
                    self?.motionCapture.detach()
                }
                if let device = device, CommandLine.arguments.contains("--audio-probe") {
                    AudioProbe.shared.attach(device)
                    BleAudioProbe.shared.start()
                }
                if CommandLine.arguments.contains("--motion-probe") {
                    if let device = device { MotionProbe.shared.attach(device) }
                    MotionProbe.shared.startGameControllerProbe()
                }
            }
        }
        // Push generation changes separately because the device-added callback
        // fires for every HID interface but only one of them holds the gen info
        // we care about — RemoteDetector dedupes on its own (lastGeneration).
        remoteDetector?.onGenerationChange = { [weak self] gen in
            rmDebug("🛰 gen callback fired: \(gen?.wireTag ?? "nil")")
            DispatchQueue.main.async {
                self?.settingsWindow?.pushGeneration(gen)
            }
        }
        remoteDetector?.startDetection()

        // Open a parallel BLE GATT connection just for the standard Battery
        // Service (0x180F) — IOHID doesn't expose battery level for Bluetooth
        // HID devices, so this is the only source. macOS allows multiple links
        // to the same peripheral, so HID keeps working in parallel.
        let batteryMonitor = BleBatteryMonitor()
        bleBatteryMonitor = batteryMonitor
        batteryMonitor.start { [weak self] level in
            self?.remoteDetector?.currentBattery = level
            self?.settingsWindow?.pushBattery(level)
        }

        // Front-app observer — flip the active profile when a bound app becomes
        // frontmost. Skip Baton itself to avoid feedback loops.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier else { return }
            self?.menuBarManager.applyAppActivation(bundleId: bid)
        }
        // Apply the current front app's preset immediately so we boot into the
        // right profile if Baton is launched while Safari/whatever is in front.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           front != Bundle.main.bundleIdentifier {
            menuBarManager.applyAppActivation(bundleId: front)
        }
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        RCDControl.restore()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        // Debounce: if the HID path just handled this button, don't double-fire.
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.2 {
                return true
            }
        }

        let action = menuBarManager.getMapping(for: buttonName)
        if action != .none {
            menuBarManager.executeAction(action.rawValue, button: buttonName)
        }
        // Always consume — no action in this app corresponds to a system media key anymore,
        // so we never want macOS's default media handler to fire.
        return true
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        // macOS will show its own prompt when needed
        // No need for redundant custom alert
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Suspends `com.apple.rcd` (Remote Control Daemon) for the user's GUI launchd domain while
/// Baton is running. rcd is what reacts to Bluetooth AVRCP play signals by launching
/// Music.app — a channel that bypasses HID seize and the cghidEventTap entirely. `bootout`
/// only affects this login session; restored on clean exit, and on next login either way.
enum RCDControl {
    private static let plistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
    private static var suspended = false

    static func suspend() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard isLoaded(service: service) else {
            print("ℹ️ com.apple.rcd not loaded; skipping suspend")
            return
        }
        let (status, err) = run(["bootout", service])
        if status == 0 {
            suspended = true
            print("🔇 com.apple.rcd suspended (Music won't auto-launch from BT remote)")
        } else {
            print("⚠️ Could not suspend com.apple.rcd (launchctl exit=\(status)): \(err)")
        }
    }

    static func restore() {
        guard suspended else { return }
        let domain = "gui/\(getuid())"
        let (status, err) = run(["bootstrap", domain, plistPath])
        if status == 0 {
            print("🔊 com.apple.rcd restored")
        } else {
            print("⚠️ Could not restore com.apple.rcd (launchctl exit=\(status)): \(err) — next login will re-register it")
        }
        suspended = false
    }

    private static func isLoaded(service: String) -> Bool {
        let (status, _) = run(["print", service], captureStderr: false)
        return status == 0
    }

    private static func run(_ args: [String], captureStderr: Bool = true) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = captureStderr ? errPipe : Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = captureStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, "\(error)")
        }
    }
}

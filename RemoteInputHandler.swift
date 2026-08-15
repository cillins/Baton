//
//  RemoteInputHandler.swift
//  Baton
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit
import CoreVideo
import OSLog

private let gyroLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.baton.app",
    category: "Gyro"
)

/// Coalesces CVDisplayLink's high-priority callbacks onto the main queue. The
/// sensor path integrates timestamped angular rates at ~67 Hz; this driver
/// posts the accumulated cursor delta at the display refresh cadence.
private final class GyroDisplayDriver {
    var onFrame: (() -> Void)?

    private var displayLink: CVDisplayLink?
    private lazy var source: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler { [weak self] in self?.onFrame?() }
        source.resume()
        return source
    }()

    func start() {
        guard displayLink == nil else { return }
        _ = source // initialize before the realtime callback can fire
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else {
            gyroLogger.error("Unable to create display link")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(link, gyroDisplayLinkCallback, context) == kCVReturnSuccess,
              CVDisplayLinkStart(link) == kCVReturnSuccess else {
            gyroLogger.error("Unable to start display link")
            return
        }
        displayLink = link
    }

    func stop() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    fileprivate func signalFrame() {
        source.add(data: 1)
    }

    deinit {
        stop()
        source.cancel()
    }
}

private func gyroDisplayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ now: UnsafePointer<CVTimeStamp>,
    _ outputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ context: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context else { return kCVReturnInvalidArgument }
    Unmanaged<GyroDisplayDriver>.fromOpaque(context).takeUnretainedValue().signalFrame()
    return kCVReturnSuccess
}

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []
    private let gyroDisplayDriver = GyroDisplayDriver()

    /// A Siri Remote publishes several HID interfaces nearly simultaneously.
    /// Opening all of them in one burst can destabilize the Bluetooth HID
    /// stack, so serialize opens and leave a short settling gap between them.
    private let seizeQueue = DispatchQueue(label: "com.baton.hidSeize")
    private var pendingSeizes: [(device: IOHIDDevice, key: UInt)] = []
    private var pendingSeizeKeys: Set<UInt> = []
    private var seizeDrainActive = false
    private var seizeEpoch: UInt64 = 0
    /// Main-thread session token. Delayed work from a disconnected remote is
    /// discarded before it can register callbacks or append a stale device.
    private var deviceSession: UInt64 = 0
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    var onRemoteMicrophoneHold: ((Bool) -> Void)?
    /// Fires on the main thread only after an HID interface has been opened
    /// and scheduled. Feature-report clients must not race the delayed open.
    var onHIDDeviceReady: ((IOHIDDevice) -> Void)?
    
    // Ignore at most one handshake press, and only shortly after connection.
    // A real first press minutes later must never be swallowed.
    private var connectionHandshakeDeadlineNanos: UInt64 = 0
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private let clickThreshold: Double = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// Captured at press time so release can fire the correct keyUp even if the user
    /// rebinds the button mid-hold. Cleared on device removal to avoid stuck modifiers.
    private var heldKeys: [String: (keyCode: Int, flags: CGEventFlags)] = [:]
    private enum RemoteMicrophoneShortcutHold {
        case keyboard(keyCode: Int, flags: CGEventFlags)
        case system(keyCode: Int32)
    }
    private var remoteMicrophoneShortcutHeld: RemoteMicrophoneShortcutHold?

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
        gyroDisplayDriver.onFrame = { [weak self] in self?.renderGyroFrame() }
    }

    deinit {
        releaseSelectIfNeeded(reason: "handler deinit")
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            deviceSession &+= 1
            seizeQueue.async { [weak self] in
                self?.seizeEpoch &+= 1
                self?.pendingSeizes.removeAll()
                self?.pendingSeizeKeys.removeAll()
                self?.seizeDrainActive = false
            }
            releaseAllHeldKeys()
            releaseSelectIfNeeded(reason: "device removed")
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            connectionHandshakeDeadlineNanos = 0
            resetGyroCalibration()
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }

        let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        let session = deviceSession
        seizeQueue.async { [weak self] in
            guard let self, self.pendingSeizeKeys.insert(key).inserted else { return }
            self.pendingSeizes.append((device, key))
            guard !self.seizeDrainActive else { return }
            self.seizeDrainActive = true
            self.drainNextSeize(session: session, epoch: self.seizeEpoch)
        }
    }

    private func drainNextSeize(session: UInt64, epoch: UInt64) {
        guard epoch == seizeEpoch else {
            seizeDrainActive = false
            return
        }
        guard !pendingSeizes.isEmpty else {
            seizeDrainActive = false
            return
        }
        let next = pendingSeizes.removeFirst()
        seizeQueue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, self.seizeEpoch == epoch else { return }
            self.openAndRegister(next.device, session: session)
            self.pendingSeizeKeys.remove(next.key)
            self.drainNextSeize(session: session, epoch: epoch)
        }
    }

    private func openAndRegister(_ device: IOHIDDevice, session: UInt64) {
        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        // A1962 voice activation is performed by macOS's HID-over-GATT stack.
        // Seizing all six logical interfaces prevents that system handshake.
        // We can still observe its values unseized, while the existing media
        // event tap and volume guard suppress the system-facing button effects.
        let shouldSeize = product != 0x026D
        var openResult = IOHIDDeviceOpen(
            device,
            shouldSeize
                ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                : IOOptionBits(kIOHIDOptionsTypeNone)
        )
        if openResult == kIOReturnSuccess {
            let mode = shouldSeize ? "SEIZED" : "OPENED UNSEIZED"
            rmDebug(String(
                format: "🔒 %@ HID device (vendor=0x%X product=0x%X)",
                mode, vendor, product
            ))
        } else if shouldSeize {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard openResult == kIOReturnSuccess else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                return
            }
            guard self.deviceSession == session else {
                rmDebug("🔒 discarding stale delayed HID open after disconnect")
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                return
            }
            guard !self.devices.contains(where: { $0 == device }) else { return }
            IOHIDDeviceRegisterInputValueCallback(
                device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDDeviceScheduleWithRunLoop(
                device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
            self.devices.append(device)
            self.onHIDDeviceReady?(device)
            if product == 0x026D {
                AudioProbe.shared.interfaceDidBecomeReady(device)
            }
            self.markConnectionHandshakeWindow()
        }
    }

    private func releaseSelectIfNeeded(reason: String) {
        guard isSelectPressed else { return }
        rmDebug("🖱 Select release fallback (\(reason))")
        isSelectPressed = false
        stopGyroCursorStream()
        if isDragging {
            cursorController.isDragging = false
            cursorController.mouseUp()
        }
        isDragging = false
        cursorController.isClickActive = false
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // A1962 exposes its continuously streaming motion payload as a
        // vendor-defined element at 0xFF00:0x10. It is sensor data (the raw
        // report is consumed by MotionCapture), not a Siri-button state.
        // Filtering it here also avoids ~70 misleading button log entries per
        // second while motion capture is enabled.
        if usagePage == 0xFF00 && usage == 0x10 { return }

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = (intValue == 1)
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed

        // Volume keys on the Siri Remote also travel over BT AVRCP absolute-volume, which
        // coreaudiod honors below cghidEventTap. Arm the revert guard on every press so the
        // CoreAudio listener snaps the level back to the pre-press value.
        if isPressed && (buttonName == "volumeUp" || buttonName == "volumeDown") {
            VolumeRevertGuard.shared.armFromRemoteButton(button: buttonName)
        }

        // Swallow one connect-handshake key-down only inside the bounded
        // window. Once the window expires, the next physical press is real.
        if intValue == 1, connectionHandshakeDeadlineNanos != 0 {
            let deadline = connectionHandshakeDeadlineNanos
            connectionHandshakeDeadlineNanos = 0
            if DispatchTime.now().uptimeNanoseconds <= deadline {
                return
            }
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        // TV is the dedicated mode-switch key (toggle system/app profile).
        if buttonName == "tv" && intValue == 1 {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
            menuBarManager?.toggleSystemOverride()
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        let action = menuBarManager?.getMapping(for: buttonName) ?? ButtonAction.none
        if pressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        executeAction(action, button: buttonName, pressed: pressed)
    }

    private func markConnectionHandshakeWindow() {
        guard connectionHandshakeDeadlineNanos == 0 else { return }
        connectionHandshakeDeadlineNanos = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            startGyroCursorStream()

            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                self.beginSelectDrag()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                stopGyroCursorStream()
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                stopGyroCursorStream()
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }

    private func beginSelectDrag() {
        guard isSelectPressed, !isDragging else { return }
        print("🔘 Select button: Drag started")
        isDragging = true
        cursorController.isDragging = true
        // The mouse-down must precede every gyro-driven cursor event; otherwise
        // an early wrist movement relocates the eventual click instead of
        // becoming part of the drag.
        cursorController.mouseDown()
    }
    
    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - known Siri button usages only. Do not
        // wildcard this page: A1962 motion data uses 0x10 on the same page.
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution

    // MARK: - Gyro cursor (gen 1): hold select, rotate the remote to drag

    /// Raw gyro units → cursor px/s. Tuned by feel; waving the remote reads
    /// in the hundreds, so 2.5 gives ~1000px/s on a fast wrist flick.
    /// Adjustable live from the settings window via applyGyroSettings.
    private var gyroGain: Double = 2.5
    /// A1962 idle traces are normally within ±2 raw units. Hysteresis keeps
    /// that quantized noise from repeatedly entering and leaving motion.
    private let gyroMotionEnterThreshold = 8.0
    private let gyroMotionExitThreshold = 4.0
    private let gyroRawStillThreshold = 5.0
    private let gyroStillSamplesRequired = 4
    /// Constant raw-rate → px/s scale. Keeping this linear is essential:
    /// integrating the same physical rotation must produce the same cursor
    /// distance regardless of how quickly the user turns the remote.
    private let gyroPointingScale = 3.2
    private let gyroBiasLearningBand = 12.0
    private let gyroBiasWindowSize = 24
    private var gyroRateCutoff = 2.2
    /// Gyro stays silent for this long after select goes down — the press
    /// itself jolts the remote and would otherwise shift the drag start point.
    private let gyroActivationDelay: Double = 0.12
    private struct GyroRateFilter {
        var minCutoff = 2.2
        var beta = 0.005
        private var value: Double?
        private var previousInput: Double?
        private var derivative = 0.0

        mutating func filter(_ input: Double, dt: Double) -> Double {
            let base = value ?? input
            let rawDerivative = previousInput.map { (input - $0) / dt } ?? 0
            previousInput = input
            let derivativeAlpha = alpha(cutoff: 1.0, dt: dt)
            derivative += derivativeAlpha * (rawDerivative - derivative)
            let adaptiveCutoff = minCutoff + beta * abs(derivative)
            let valueAlpha = alpha(cutoff: adaptiveCutoff, dt: dt)
            let filtered = base + valueAlpha * (input - base)
            value = filtered
            return filtered
        }

        mutating func reset() {
            value = nil
            previousInput = nil
            derivative = 0
        }

        private func alpha(cutoff: Double, dt: Double) -> Double {
            1.0 - exp(-2.0 * .pi * cutoff * dt)
        }
    }

    private struct GyroBiasSample {
        let x: Double
        let y: Double
        let z: Double
    }

    private var gyroBias = (x: 0.0, y: 0.0, z: 0.0)
    private var gyroBiasInitialized = false
    private var gyroBiasSamples: [GyroBiasSample] = []
    private var gyroFilterX = GyroRateFilter()
    private var gyroFilterY = GyroRateFilter()
    private var previousGyroRate: (x: Double, y: Double)?
    private var gyroMotionActive = false
    private var gyroMotionCandidateSamples = 0
    private var gyroStillSamples = 0
    private var gyroSubpixel = (x: 0.0, y: 0.0)
    private var gyroRenderVelocity = (x: 0.0, y: 0.0)
    private var lastGyroSampleTime: UInt64 = 0
    private var lastGyroRenderTime: UInt64 = 0
    private let gyroVelocityHoldTimeout = 0.055
    private var gyroStreamStartedAt: UInt64 = 0
    private var gyroInputFrames = 0
    private var gyroDisplayFrames = 0
    private var gyroMovedFrames = 0
    private var gyroMaxInputGap = 0.0

    /// Live-apply settings-window changes. Smoothing is applied independently
    /// to each angular-rate axis before integration.
    func applyGyroSettings(gain: Double, minCutoff: Double) {
        gyroGain = gain
        gyroRateCutoff = minCutoff
        gyroFilterX.minCutoff = minCutoff
        gyroFilterY.minCutoff = minCutoff
        resetGyroRateState()
    }

    /// Called from MotionCapture's IOHID callback thread at ~50-90Hz.
    /// Only moves the cursor while select is held (drag mode).
    /// Axis mapping for an upright, wand-style hold (buttons facing the user):
    /// horizontal pointing is yaw around Z; vertical pointing is pitch around
    /// X. Mapping horizontal to Y makes banking/side-tilting the remote move the
    /// cursor, which is not the intended air-mouse gesture.
    func handleGyro(x: Int16, y: Int16, z: Int16, timestamp: UInt64) {
        // MotionCapture delivers off-main while CVDisplayLink renders on main.
        // Serialize both paths so partially-updated tuple state cannot produce
        // intermittent jumps or reversed one-frame deltas.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGyro(x: x, y: y, z: z, timestamp: timestamp)
            }
            return
        }

        let sensorX = Double(x)
        let sensorY = Double(y)
        guard isSelectPressed else {
            learnGyroBias(x: sensorX, y: sensorY, z: Double(z))
            return
        }

        // Activation grace period: swallow the press jolt so the drag start
        // point stays where the user pressed. Bias is deliberately not learned
        // here because these samples are contaminated by button pressure.
        guard timestamp >= selectPressTime else { return }
        let heldFor = Double(timestamp - selectPressTime)
            * Double(machTimebase.numer) / Double(machTimebase.denom) / 1e9
        guard heldFor > gyroActivationDelay else {
            resetGyroRateState()
            return
        }

        if lastGyroSampleTime != 0 {
            let gap = seconds(from: lastGyroSampleTime, to: timestamp)
            gyroMaxInputGap = max(gyroMaxInputGap, gap)
        }
        gyroInputFrames += 1
        guard lastGyroSampleTime != 0 else {
            lastGyroSampleTime = timestamp
            return
        }
        let dt = seconds(from: lastGyroSampleTime, to: timestamp)
        lastGyroSampleTime = timestamp
        guard dt > 0 else { return }
        // A long gap contains no trustworthy trajectory. Reset instead of
        // fabricating a large cursor jump from one stale angular-rate sample.
        guard dt <= 0.12 else {
            resetGyroRateState(keepTimestamp: timestamp)
            return
        }

        // Bias-subtract, filter each rate axis independently, then integrate
        // with a trapezoidal step. There is deliberately no speed acceleration,
        // so equal angular displacement maps to equal cursor distance.
        // Core Graphics positive X points right. A1962's Z yaw sign is opposite
        // Quartz X, so the inversion is part of the fixed axis calibration.
        let horizontal = Double(z) - gyroBias.z
        let rawX = -horizontal
        let rawY = -(Double(x) - gyroBias.x)
        let unusedRoll = Double(y) - gyroBias.y

        // A true rest sample must be quiet on all three gyro axes. While held,
        // several consecutive rest samples hard-reset filter history so noise
        // can never accumulate into cursor drift.
        if abs(rawX) < gyroRawStillThreshold,
           abs(rawY) < gyroRawStillThreshold,
           abs(unusedRoll) < gyroRawStillThreshold {
            gyroRenderVelocity = (0, 0)
            gyroStillSamples += 1
            if gyroStillSamples >= gyroStillSamplesRequired {
                resetGyroRateState(keepTimestamp: timestamp)
                gyroStillSamples = gyroStillSamplesRequired
            }
            return
        }
        gyroStillSamples = 0

        if !gyroMotionActive {
            guard hypot(rawX, rawY) > gyroMotionEnterThreshold else {
                gyroMotionCandidateSamples = 0
                gyroRenderVelocity = (0, 0)
                return
            }
            gyroMotionCandidateSamples += 1
            guard gyroMotionCandidateSamples >= 2 else { return }
            gyroMotionActive = true
            gyroMotionCandidateSamples = 0
            // A meaningful wrist movement converts the pending click into a
            // drag before the first cursor event, even before the hold timer.
            beginSelectDrag()
        }

        let filteredX = gyroFilterX.filter(rawX, dt: dt)
        let filteredY = gyroFilterY.filter(rawY, dt: dt)
        let magnitude = hypot(filteredX, filteredY)

        if gyroMotionActive {
            if magnitude < gyroMotionExitThreshold {
                gyroStillSamples += 1
                if gyroStillSamples >= gyroStillSamplesRequired {
                    gyroMotionActive = false
                    previousGyroRate = nil
                    return
                }
            } else {
                gyroStillSamples = 0
            }
        }

        let correctedX = filteredX - copysign(gyroMotionExitThreshold, filteredX)
        let correctedY = filteredY - copysign(gyroMotionExitThreshold, filteredY)
        let rateX = abs(filteredX) > gyroMotionExitThreshold ? correctedX : 0
        let rateY = abs(filteredY) > gyroMotionExitThreshold ? correctedY : 0
        let averageRateX = previousGyroRate.map { ($0.x + rateX) * 0.5 } ?? rateX
        let averageRateY = previousGyroRate.map { ($0.y + rateY) * 0.5 } ?? rateY
        previousGyroRate = (rateX, rateY)
        let velocityScale = gyroGain * gyroPointingScale
        gyroRenderVelocity.x = averageRateX * velocityScale
        gyroRenderVelocity.y = averageRateY * velocityScale
    }

    private func learnGyroBias(x: Double, y: Double, z: Double) {
        gyroBiasSamples.append(GyroBiasSample(x: x, y: y, z: z))
        if gyroBiasSamples.count > gyroBiasWindowSize {
            gyroBiasSamples.removeFirst(gyroBiasSamples.count - gyroBiasWindowSize)
        }
        guard gyroBiasSamples.count == gyroBiasWindowSize else { return }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func stableMedian(_ values: [Double]) -> Double? {
            guard let minimum = values.min(), let maximum = values.max(),
                  maximum - minimum <= 4.0 else { return nil }
            return median(values)
        }

        guard let candidateX = stableMedian(gyroBiasSamples.map(\.x)),
              let candidateY = stableMedian(gyroBiasSamples.map(\.y)),
              let candidateZ = stableMedian(gyroBiasSamples.map(\.z)) else { return }

        if !gyroBiasInitialized {
            gyroBias = (candidateX, candidateY, candidateZ)
            gyroBiasInitialized = true
            rmDebug(String(
                format: "🌀 gyro bias calibrated: x=%.2f y=%.2f z=%.2f",
                gyroBias.x, gyroBias.y, gyroBias.z
            ))
            return
        }

        let biasDistance = sqrt(
            pow(candidateX - gyroBias.x, 2)
            + pow(candidateY - gyroBias.y, 2)
            + pow(candidateZ - gyroBias.z, 2)
        )
        guard biasDistance < gyroBiasLearningBand else {
            return
        }
        gyroBias.x += (candidateX - gyroBias.x) * 0.08
        gyroBias.y += (candidateY - gyroBias.y) * 0.08
        gyroBias.z += (candidateZ - gyroBias.z) * 0.08
    }

    private func resetGyroRateState(keepTimestamp timestamp: UInt64 = 0) {
        gyroFilterX.reset()
        gyroFilterY.reset()
        gyroFilterX.minCutoff = gyroRateCutoff
        gyroFilterY.minCutoff = gyroRateCutoff
        previousGyroRate = nil
        gyroMotionActive = false
        gyroMotionCandidateSamples = 0
        gyroStillSamples = 0
        gyroRenderVelocity = (0, 0)
        lastGyroSampleTime = timestamp
    }

    private func resetGyroCalibration() {
        gyroBias = (0, 0, 0)
        gyroBiasInitialized = false
        gyroBiasSamples.removeAll(keepingCapacity: true)
        resetGyroMotionState()
    }

    private func resetGyroMotionState() {
        resetGyroRateState()
        gyroSubpixel = (0, 0)
        lastGyroRenderTime = 0
    }

    private func startGyroCursorStream() {
        resetGyroMotionState()
        gyroStreamStartedAt = mach_absolute_time()
        gyroInputFrames = 0
        gyroDisplayFrames = 0
        gyroMovedFrames = 0
        gyroMaxInputGap = 0
        gyroDisplayDriver.start()
        gyroLogger.info("Cursor stream started")
        rmDebug("🌀 cursor stream started biasReady=\(gyroBiasInitialized)")
    }

    private func stopGyroCursorStream() {
        gyroDisplayDriver.stop()
        let now = mach_absolute_time()
        let duration = seconds(from: gyroStreamStartedAt, to: now)
        if duration >= 0.25 {
            let inputHz = Double(gyroInputFrames) / duration
            let displayHz = Double(gyroDisplayFrames) / duration
            gyroLogger.info(
                "Cursor stream stopped duration=\(duration, format: .fixed(precision: 2))s inputHz=\(inputHz, format: .fixed(precision: 1)) displayHz=\(displayHz, format: .fixed(precision: 1)) movedFrames=\(self.gyroMovedFrames) maxInputGapMs=\(self.gyroMaxInputGap * 1000, format: .fixed(precision: 1))"
            )
            rmDebug(String(
                format: "🌀 cursor stream stopped duration=%.2fs inputHz=%.1f displayHz=%.1f movedFrames=%d maxInputGapMs=%.1f biasReady=%@",
                duration, inputHz, displayHz, gyroMovedFrames, gyroMaxInputGap * 1000,
                gyroBiasInitialized ? "yes" : "no"
            ))
        }
        resetGyroMotionState()
    }

    private func renderGyroFrame() {
        guard isSelectPressed else { return }
        let now = mach_absolute_time()
        gyroDisplayFrames += 1
        guard lastGyroRenderTime != 0 else {
            lastGyroRenderTime = now
            return
        }
        var dt = seconds(from: lastGyroRenderTime, to: now)
        lastGyroRenderTime = now
        dt = min(max(dt, 0.001), 0.025)
        guard isDragging else { return }

        // Resample the latest filtered sensor velocity at display cadence.
        // Brief 30–45 ms BLE gaps keep moving smoothly; a longer gap is
        // treated as a stopped/stale sensor and cannot cause cursor drift.
        if lastGyroSampleTime == 0
            || seconds(from: lastGyroSampleTime, to: now) > gyroVelocityHoldTimeout {
            gyroRenderVelocity = (0, 0)
        }
        gyroSubpixel.x += gyroRenderVelocity.x * dt
        gyroSubpixel.y += gyroRenderVelocity.y * dt
        let dx = gyroSubpixel.x.rounded(.towardZero)
        let dy = gyroSubpixel.y.rounded(.towardZero)
        gyroSubpixel.x -= dx
        gyroSubpixel.y -= dy
        guard dx != 0 || dy != 0 else { return }
        gyroMovedFrames += 1
        _ = cursorController.moveCursor(
            deltaX: CGFloat(dx), deltaY: CGFloat(dy), applyPointerTuning: false
        )
    }

    private func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard start != 0, end >= start else { return 0 }
        return Double(end - start)
            * Double(machTimebase.numer) / Double(machTimebase.denom) / 1e9
    }

    private let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        // Release the exact key captured at press time even if the mapping was
        // edited while the remote button was still held.
        if !pressed, let held = heldKeys.removeValue(forKey: button) {
            releaseHeldKey(held)
            return
        }
        if action.requiresHold {
            handleHoldAction(action, button: button, pressed: pressed)
            return
        }
        if action == .customKey,
           holdCapableButtons.contains(button),
           let combo = menuBarManager?.customKeyCombo(forButton: button),
           combo["systemKeyCode"] == nil {
            handleCustomKeyHold(combo: combo, button: button, pressed: pressed)
            return
        }
        // Tap actions fire once, on press only.
        guard pressed else { return }
        switch action {
        case .none:
            break
        case .enterKey:
            sendKey(kVK_Return)
        case .upKey:
            sendKey(kVK_UpArrow)
        case .downKey:
            sendKey(kVK_DownArrow)
        case .leftKey:
            sendKey(kVK_LeftArrow)
        case .rightKey:
            sendKey(kVK_RightArrow)
        case .bKey:
            sendKey(kVK_ANSI_B)
        case .wKey:
            sendKey(kVK_ANSI_W)
        case .escKey:
            sendKey(kVK_Escape)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .spaceKey, .rightCmd, .rightOpt, .remoteMicrophone:
            break // handled by handleHoldAction
        case .mediaPlayPause, .mediaNext, .mediaPrev, .mediaMute:
            menuBarManager?.executeAction(action.rawValue, button: button)
        case .systemVolumeUp, .systemVolumeDown:
            menuBarManager?.executeAction(action.rawValue, button: button)
        case .presentation:
            sendKey(kVK_ANSI_P, flags: [.maskCommand, .maskAlternate])
        case .trackpadClick:
            cursorController.performClick()
        case .customText:
            if let text = menuBarManager?.customText(forButton: button) {
                menuBarManager?.executeCustomText(text)
            }
        case .customKey:
            if let combo = menuBarManager?.customKeyCombo(forButton: button),
               let keyCode = combo["keyCode"] as? Int,
               let modifiers = combo["modifiers"] as? [String] {
                menuBarManager?.executeCustomKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    systemKeyCode: combo["systemKeyCode"] as? Int,
                    sourceButton: button
                )
            }
        }
    }

    /// Press/release a virtual key mirroring the HID press duration (push-to-talk).
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
        if action == .remoteMicrophone {
            if pressed, !AudioProbe.shared.ownsA1962Activation {
                enableRemoteMicrophoneStream()
            }
            onRemoteMicrophoneHold?(pressed)
            return
        }
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .spaceKey: spec = (kVK_Space,        [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption,  .maskAlternate)
        default: return
        }

        if pressed {
            // Defensive: if a prior release was missed, close the stale hold before opening a new one.
            if let stale = heldKeys.removeValue(forKey: button) {
                releaseHeldKey(stale)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
            heldKeys[button] = spec
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    private func enableRemoteMicrophoneStream() {
        // Legacy fallback for remotes not owned by AudioProbe. A1962 normally
        // performs this compact handshake once, after every HID callback is
        // live, through AudioProbe.interfaceDidBecomeReady(_:).
        let microphoneUsages: [(page: Int, usage: Int)] = [
            (0x0C, 0x04),
            (0x0D, 0x01),
        ]
        let enableTargets = microphoneUsages.compactMap { target in
            devices.first { device in
                let page = IOHIDDeviceGetProperty(
                    device, kIOHIDPrimaryUsagePageKey as CFString
                ) as? Int
                let usage = IOHIDDeviceGetProperty(
                    device, kIOHIDPrimaryUsageKey as CFString
                ) as? Int
                return page == target.page && usage == target.usage
            }
        }
        guard enableTargets.count == microphoneUsages.count else {
            rmDebug("🎙 microphone HID control interfaces not found")
            return
        }
        let firstResult = sendRemoteMicrophoneEnable(
            to: enableTargets[0], probeIndex: 0
        )
        // IOHIDDeviceSetReport is synchronous: when the 0x001D call returns,
        // its ATT Write Response has already arrived. Apple's successful trace
        // sends 0x0020 one millisecond later, so keep both writes in this same
        // call chain instead of waiting for PacketLogger/helper IPC.
        if firstResult == kIOReturnSuccess, buttonState["siri"] == true {
            _ = sendRemoteMicrophoneEnable(to: enableTargets[1], probeIndex: 1)
            // Match the AudioProbe broadcast that produced the known-good HCI
            // capture. The four sibling interfaces accept the compact report
            // and complete the composite-device activation sequence.
            for device in devices where
                device != enableTargets[0] && device != enableTargets[1] {
                _ = sendRemoteMicrophoneEnable(to: device, probeIndex: 2)
            }
        }
    }

    /// The helper invokes this only after the ATT Write Response for 0x001D.
    func completeRemoteMicrophoneHandshake() {
        guard buttonState["siri"] == true,
              let device = devices.first(where: { device in
                  let page = IOHIDDeviceGetProperty(
                      device, kIOHIDPrimaryUsagePageKey as CFString
                  ) as? Int
                  let usage = IOHIDDeviceGetProperty(
                      device, kIOHIDPrimaryUsageKey as CFString
                  ) as? Int
                  return page == 0x0D && usage == 0x01
              }) else { return }
        _ = sendRemoteMicrophoneEnable(to: device, probeIndex: 1)
    }

    @discardableResult
    private func sendRemoteMicrophoneEnable(
        to device: IOHIDDevice, probeIndex: Int
    ) -> IOReturn {
            let page = IOHIDDeviceGetProperty(
                device, kIOHIDPrimaryUsagePageKey as CFString
            ) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(
                device, kIOHIDPrimaryUsageKey as CFString
            ) as? Int ?? 0
            let result: IOReturn
            // Existing implementations send the input-enable value as one
            // compact report. The old 208-byte fallback was only a descriptor
            // size experiment and generated unnecessary Prepare Write traffic.
            let report: [UInt8] = [0xAF]
            result = report.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    device, kIOHIDReportTypeFeature, 255,
                    buffer.baseAddress!, buffer.count
                )
            }
            rmDebug(String(
                format: "🎙 mic probe[%d] page=0x%X usage=0x%X result=0x%X",
                probeIndex, page, usage, result
            ))
            return result
    }

    /// Called only after the privileged HCI capture process reports ready, so
    /// the first Opus packets are not lost while PacketLogger is starting.
    func beginRemoteMicrophoneStream() {
        guard buttonState["siri"] == true else { return }
        enableRemoteMicrophoneStream()
    }

    private func handleCustomKeyHold(combo: [String: Any], button: String, pressed: Bool) {
        guard pressed,
              let keyCode = combo["keyCode"] as? Int,
              let modifiers = combo["modifiers"] as? [String] else { return }
        if let stale = heldKeys.removeValue(forKey: button) {
            releaseHeldKey(stale)
        }
        let isFn = keyCode == kVK_Function || modifiers.contains("fn")
        let flags: CGEventFlags = isFn
            ? .maskSecondaryFn
            : MenuBarManager.flags(fromModifierNames: modifiers)
        if isFn {
            postFnKey(down: true)
        } else {
            postKey(keyCode: keyCode, flags: flags, keyDown: true)
        }
        heldKeys[button] = (keyCode, flags)
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys() {
        onRemoteMicrophoneHold?(false)
        setRemoteMicrophoneShortcutHeld(false)
        for (_, held) in heldKeys {
            releaseHeldKey(held)
        }
        heldKeys.removeAll()
        buttonState.removeAll()
    }

    /// Holds the optional companion shortcut only while a remote-microphone
    /// voice session is active. The key spec is captured on key-down so a
    /// settings change mid-press cannot leave the previous key stuck.
    func setRemoteMicrophoneShortcutHeld(_ held: Bool) {
        if !held {
            guard let active = remoteMicrophoneShortcutHeld else { return }
            remoteMicrophoneShortcutHeld = nil
            switch active {
            case .keyboard(let keyCode, let flags):
                releaseHeldKey((keyCode, flags))
            case .system(let keyCode):
                menuBarManager?.mediaController?.setSystemKey(
                    nxKeyCode: keyCode, keyDown: false
                )
            }
            return
        }
        guard remoteMicrophoneShortcutHeld == nil,
              let combo = menuBarManager?.remoteMicrophoneHoldKeyCombo() else { return }
        if let systemKeyCode = combo["systemKeyCode"] as? Int {
            let keyCode = Int32(systemKeyCode)
            menuBarManager?.mediaController?.setSystemKey(
                nxKeyCode: keyCode, keyDown: true
            )
            remoteMicrophoneShortcutHeld = .system(keyCode: keyCode)
            let label = combo["label"] as? String ?? "system key \(systemKeyCode)"
            rmDebug("🎙 companion shortcut key-down: \(label)")
            return
        }
        guard let keyCode = combo["keyCode"] as? Int,
              let modifiers = combo["modifiers"] as? [String] else { return }
        let isFn = keyCode == kVK_Function || modifiers.contains("fn")
        let flags: CGEventFlags = isFn
            ? .maskSecondaryFn
            : MenuBarManager.flags(fromModifierNames: modifiers)
        if isFn {
            postFnKey(down: true)
        } else {
            postKey(keyCode: keyCode, flags: flags, keyDown: true)
        }
        remoteMicrophoneShortcutHeld = .keyboard(keyCode: keyCode, flags: flags)
        let label = combo["label"] as? String ?? "key \(keyCode)"
        rmDebug("🎙 companion shortcut key-down: \(label)")
    }

    private func releaseHeldKey(_ held: (keyCode: Int, flags: CGEventFlags)) {
        if held.keyCode == kVK_Function || held.flags.contains(.maskSecondaryFn) {
            postFnKey(down: false)
        } else {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    private func postFnKey(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
        event.flags = down ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}

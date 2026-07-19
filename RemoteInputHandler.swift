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

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
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

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            releaseAllHeldKeys()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            isFirstPressAfterConnection = true
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                isFirstPressAfterConnection = true
            }
        }
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

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
            VolumeRevertGuard.shared.armFromRemoteButton()
        }

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
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
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true

            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
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
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
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
    /// Noise floor after smoothing — enter motion above this, keep moving until
    /// the signal drops under the still band below (hysteresis).
    private let gyroDeadzone: Double = 8
    /// All three axes under this for a few samples = remote is being held still:
    /// freeze the cursor and re-learn the gyro bias (kills rest jitter + drift).
    private let gyroStillBand: Int16 = 12
    /// One Euro filter per axis: speed-adaptive smoothing — heavy filtering at
    /// tremor speeds, nearly none on fast swings. minCutoff = smoothing at rest
    /// (lower = smoother), beta = how fast the filter opens up with speed.
    private struct OneEuro {
        var minCutoff = 0.8
        var beta = 0.005
        private var xPrev: Double?
        private var dxPrev = 0.0
        init(minCutoff: Double = 0.8, beta: Double = 0.005) {
            self.minCutoff = minCutoff
            self.beta = beta
        }
        mutating func filter(_ x: Double, dt: Double) -> Double {
            let dx = xPrev.map { (x - $0) / dt } ?? 0
            let aD = alpha(cutoff: 1.0, dt: dt)
            let dxHat = dxPrev + aD * (dx - dxPrev)
            let cutoff = minCutoff + beta * abs(dxHat)
            let a = alpha(cutoff: cutoff, dt: dt)
            let base = xPrev ?? x
            let xHat = base + a * (x - base)
            xPrev = xHat
            dxPrev = dxHat
            return xHat
        }
        mutating func reset() { xPrev = nil; dxPrev = 0 }
        private func alpha(cutoff: Double, dt: Double) -> Double {
            let tau = 1.0 / (2 * .pi * cutoff)
            return 1.0 / (1.0 + tau / dt)
        }
    }
    /// Gyro stays silent for this long after select goes down — the press
    /// itself jolts the remote and would otherwise shift the drag start point.
    private let gyroActivationDelay: Double = 0.35
    private var lastGyroTime: UInt64 = 0
    private var gyroBias = (x: 0.0, y: 0.0, z: 0.0)
    private var gyroStillSamples = 0
    private var gyroFilterX = OneEuro()
    private var gyroFilterY = OneEuro()

    /// Live-apply settings-window changes: new gain + One Euro smoothing strength.
    /// Filters reset so a parameter jump doesn't leave residual smoothed output.
    func applyGyroSettings(gain: Double, minCutoff: Double) {
        gyroGain = gain
        gyroFilterX.minCutoff = minCutoff
        gyroFilterY.minCutoff = minCutoff
        gyroFilterX.reset()
        gyroFilterY.reset()
    }

    /// Called from MotionCapture's IOHID callback thread at ~50-90Hz.
    /// Only moves the cursor while select is held (drag mode).
    /// Axis mapping (wand-style hold, buttons up; verified by feel):
    /// yaw = -Z, pitch = -X.
    func handleGyro(x: Int16, y: Int16, z: Int16) {
        guard isSelectPressed else {
            lastGyroTime = 0
            gyroStillSamples = 0
            gyroFilterX.reset()
            gyroFilterY.reset()
            return
        }

        // Activation grace period: swallow the press jolt so the drag start
        // point stays where the user pressed.
        let heldFor = Double(mach_absolute_time() - selectPressTime)
            * Double(machTimebase.numer) / Double(machTimebase.denom) / 1e9
        guard heldFor > gyroActivationDelay else {
            lastGyroTime = 0
            return
        }

        // Stationary detection: freeze + update bias estimate, skip output.
        if abs(x) < gyroStillBand && abs(y) < gyroStillBand && abs(z) < gyroStillBand {
            gyroStillSamples += 1
            if gyroStillSamples > 10 {
                gyroBias.x = gyroBias.x * 0.95 + Double(x) * 0.05
                gyroBias.y = gyroBias.y * 0.95 + Double(y) * 0.05
                gyroBias.z = gyroBias.z * 0.95 + Double(z) * 0.05
                gyroFilterX.reset()
                gyroFilterY.reset()
            }
            lastGyroTime = 0
            return
        }
        gyroStillSamples = 0

        let now = mach_absolute_time()
        defer { lastGyroTime = now }
        guard lastGyroTime != 0 else { return } // drop first sample (no dt)
        var dt = Double(now - lastGyroTime) * Double(machTimebase.numer) / Double(machTimebase.denom) / 1e9
        dt = min(max(dt, 0.001), 0.1)

        // Bias-subtract, One-Euro smooth, deadzone, then integrate to cursor delta.
        let rawX = -(Double(z) - gyroBias.z)
        let rawY = -(Double(x) - gyroBias.x)
        let smoothX = gyroFilterX.filter(rawX, dt: dt)
        let smoothY = gyroFilterY.filter(rawY, dt: dt)
        let dx = abs(smoothX) < gyroDeadzone ? 0 : smoothX * gyroGain * dt
        let dy = abs(smoothY) < gyroDeadzone ? 0 : smoothY * gyroGain * dt
        guard dx != 0 || dy != 0 else { return }
        _ = cursorController.moveCursor(deltaX: CGFloat(dx), deltaY: CGFloat(dy))
    }

    private let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        if action.requiresHold {
            handleHoldAction(action, button: button, pressed: pressed)
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
        case .escKey:
            sendKey(kVK_Escape)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .spaceKey, .rightCmd, .rightOpt:
            break // handled by handleHoldAction
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
                menuBarManager?.executeCustomKey(keyCode: keyCode, modifiers: modifiers)
            }
        }
    }

    /// Press/release a virtual key mirroring the HID press duration (push-to-talk).
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
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
                postKey(keyCode: stale.keyCode, flags: [], keyDown: false)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
            heldKeys[button] = spec
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys() {
        for (_, held) in heldKeys {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
        heldKeys.removeAll()
        buttonState.removeAll()
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

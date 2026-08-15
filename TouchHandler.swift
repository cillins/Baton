//
//  TouchHandler.swift
//  Baton
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import CoreVideo
import AppKit
import Darwin

/// Coalesces raw multitouch callbacks to the active display's refresh cadence.
/// The callback can arrive off-main and faster than AppKit can safely process;
/// a data-add source avoids building an unbounded queue of stale cursor frames.
private final class TouchDisplayDriver {
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
        _ = source
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link,
              CVDisplayLinkSetOutputCallback(link, touchDisplayLinkCallback,
                                             Unmanaged.passUnretained(self).toOpaque()) == kCVReturnSuccess,
              CVDisplayLinkStart(link) == kCVReturnSuccess else {
            rmDebug("📱 Unable to start touch display link")
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

private func touchDisplayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ now: UnsafePointer<CVTimeStamp>,
    _ outputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ context: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context else { return kCVReturnError }
    Unmanaged<TouchDisplayDriver>.fromOpaque(context).takeUnretainedValue().signalFrame()
    return kCVReturnSuccess
}

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(touches: touches, count: numTouches, timestamp: timestamp)
}

class TouchHandler {
    
    /// mach_absolute_time() is in machine-dependent units; convert to seconds via timebase.
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        if mach_timebase_info(&info) == 0 {
            return (info.numer, info.denom)
        }
        return (1, 1)
    }()
    
    private static func machDeltaToSeconds(from startMach: UInt64) -> Double {
        guard startMach > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= startMach ? (now - startMach) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private let cursorController: CursorController
    private let displayDriver = TouchDisplayDriver()
    private let cursorDeltaLock = NSLock()
    private var pendingCursorDelta = CGPoint.zero
    private var device: MTDevice?
    private var reconnectTimer: Timer?
    private var fastReconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    
    var scrollScale: CGFloat = 150.0

    /// Single-finger cursor multiplier; adjustable live from the settings window.
    var cursorScale: CGFloat = 500.0

    /// Trackpad mode: "mouse" = cursor control (no swipe actions);
    /// "gesture" = swipe shortcuts only (no cursor movement).
    var trackpadMode: String = "mouse"
    
    private var lastTouchPosition: CGPoint?
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0
    private var touchStartTime: UInt64 = 0
    private var touchStartPosition: CGPoint = .zero
    
    private let tapMaxDuration: Double = 0.22
    private let tapMaxDistance: CGFloat = 0.07
    // Swipe detection: velocity-gated single-finger flick. Distance > 35% of trackpad in < 350ms,
    // with the dominant axis at least 2× the orthogonal axis (rejects diagonal wobble).
    private let swipeMinDistance: CGFloat = 0.35
    private let swipeMaxDuration: Double = 0.35
    private let swipeAxisRatio: CGFloat = 2.0
    private var hadMultipleFingersInSession = false

    /// Fired on touch-up when a single-finger flick is detected. Dispatched on main.
    var onSwipe: ((SwipeDirection) -> Void)?
    private let reconnectInterval: TimeInterval = 2.0
    private let touchStarvationThreshold: TimeInterval = 15.0
    private var starvationConfirmations = 0

    init(cursorController: CursorController) {
        self.cursorController = cursorController
        displayDriver.onFrame = { [weak self] in self?.renderCursorFrame() }
    }
    
    deinit {
        stop()
    }
    
    func start() {
        findAndStartDevice()
        startReconnectTimer()
        // Restart MT device after sleep (trackpad stops delivering until restarted).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartTrackpadAfterWake()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        fastReconnectTimer?.invalidate()
        fastReconnectTimer = nil
        stopDevice()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// only when we don't have a device, so we can reattach if it reappeared. If we already
    /// have a working device, do nothing — restarting on every button press would break the trackpad.
    func tryReconnectTrackpad() {
        guard device == nil else { return }
        let doScan = { [weak self] in
            guard self?.device == nil else { return }
            self?.findAndStartDevice()
        }
        if Thread.isMainThread {
            doScan()
        } else {
            DispatchQueue.main.async { doScan() }
        }
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // Poll more often for a limited time so we attach as soon as the trackpad reappears.
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.device != nil {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndStartDevice()
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopDevice()
        findAndStartDevice()
    }

    private static func parseDeviceID(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed)
    }
    
    private func findAndStartDevice() {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceList = cfArray as [MTDevice]

        // Optional escape hatch for unknown hardware/firmware combinations:
        // defaults write com.baton.app trackpadDeviceID -string 0x<device-id>
        let pinnedID = UserDefaults.standard.string(forKey: "trackpadDeviceID")
            .flatMap(Self.parseDeviceID)
        var chosen: (device: MTDevice, area: Int64)?

        for dev in deviceList {
            var deviceID: UInt64 = 0
            var width: Int32 = 0
            var height: Int32 = 0
            MTDeviceGetDeviceID(dev, &deviceID)
            MTDeviceGetSensorSurfaceDimensions(dev, &width, &height)
            let builtIn = MTDeviceIsBuiltIn(dev)
            rmDebug(String(
                format: "📱 MT candidate id=0x%llX surface=%dx%d builtIn=%@",
                deviceID, width, height, builtIn ? "yes" : "no"
            ))

            if let pinnedID, deviceID == pinnedID {
                rmDebug(String(format: "📱 selecting pinned MT device 0x%llX", deviceID))
                startDevice(dev)
                return
            }
            guard pinnedID == nil else { continue }
            guard RemoteTouchSurface.isEligible(width: width, height: height, builtIn: builtIn) else {
                continue
            }
            let area = Int64(width) * Int64(height)
            if let current = chosen {
                if area < current.area {
                    chosen = (dev, area)
                }
            } else {
                chosen = (dev, area)
            }
        }

        if let chosen {
            startDevice(chosen.device)
            return
        }

        // Fail closed: never adopt an unrelated Magic Trackpad just because it
        // is the only external multitouch device currently visible.
        if device != nil {
            stopDevice()
        }
    }
    
    private func startDevice(_ dev: MTDevice) {
        stopDevice()
        device = dev
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        starvationConfirmations = 0
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        var deviceID: UInt64 = 0
        MTDeviceGetDeviceID(dev, &deviceID)
        rmDebug(String(format: "📱 Trackpad device connected and started (id=0x%llX)", deviceID))
    }
    
    private func stopDevice() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        device = nil
        displayDriver.stop()
        discardPendingCursorMovement()
        
        rmDebug("📱 Trackpad device disconnected")
        lastTouchPosition = nil
        lastTouchCount = 0
        hadMultipleFingersInSession = false
    }
    
    private func startReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        // Fire when app is in background (menu bar only); otherwise timer may not run.
        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func checkAndReconnect() {
        let timeSinceLastTouch = lastTouchTime == 0 ? 0 : Self.machDeltaToSeconds(from: lastTouchTime)

        guard let dev = device else {
            findAndStartDevice()
            return
        }

        // A healthy device needs no enumeration. MTDeviceCreateList performs
        // synchronous driver IPC and previously stalled the main thread every 2s.
        guard MTDeviceIsRunning(dev) else {
            starvationConfirmations = 0
            findAndStartDevice()
            return
        }

        // A sleeping remote can remain "running" while silently delivering no
        // frames. Require two idle checks before restarting so a frame arriving
        // near the threshold cancels the restart instead of being interrupted.
        if lastTouchCount == 0 && timeSinceLastTouch > touchStarvationThreshold {
            starvationConfirmations += 1
        } else {
            starvationConfirmations = 0
        }
        if starvationConfirmations >= 2 {
            starvationConfirmations = 0
            findAndStartDevice()
        }
    }
    
    func handleTouches(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        lastTouchTime = mach_absolute_time()

        guard count > 0, let touchPtr = touches else {
            // Touch ended
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        // Calculate average position of all active touches
        var avgX: Float = 0
        var avgY: Float = 0
        var activeTouchCount = 0
        
        for i in 0..<count {
            let touch = touchPtr[i]
            
            // Only process active touches
            if touch.state == MTTouchStateTouching || touch.state == MTTouchStateMakeTouch {
                avgX += touch.normalizedVector.position.x
                avgY += touch.normalizedVector.position.y
                activeTouchCount += 1
            }
        }
        
        guard activeTouchCount > 0 else {
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        if activeTouchCount >= 2 {
            hadMultipleFingersInSession = true
        }
        
        avgX /= Float(activeTouchCount)
        avgY /= Float(activeTouchCount)
        
        let currentPos = CGPoint(x: CGFloat(avgX), y: CGFloat(avgY))

        // The physical Select click is also the gyro drag trigger. While it is
        // held, finger pressure changes the reported contact centroid even if
        // the finger is not intentionally moving. Feeding that noise into the
        // cursor at the same time as gyro input makes a drag wander or jump.
        // Keep consuming frames so release resumes from the current contact
        // position, but let gyro be the only cursor source during the hold.
        if cursorController.isClickActive {
            discardPendingCursorMovement()
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }
        
        // Handle touch start
        if lastTouchPosition == nil {
            hadMultipleFingersInSession = false
            touchStartTime = mach_absolute_time()
            touchStartPosition = currentPos
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }
        
        // Calculate delta
        let deltaX = currentPos.x - (lastTouchPosition?.x ?? currentPos.x)
        let deltaY = currentPos.y - (lastTouchPosition?.y ?? currentPos.y)
        
        // Process based on finger count: 1 finger = cursor, 2 fingers = scroll
        if activeTouchCount == 1 && lastTouchCount == 1 {
            // In gesture mode, skip cursor movement entirely.
            if trackpadMode == "gesture" {
                lastTouchPosition = currentPos
            } else {
                enqueueCursorMovement(deltaX: deltaX, deltaY: deltaY)
                lastTouchPosition = currentPos
            }
        } else if activeTouchCount == 2 && lastTouchCount == 2 {
            // Two fingers: always scroll regardless of mode
            performScroll(deltaX: deltaX, deltaY: deltaY)
            lastTouchPosition = currentPos
        } else {
            lastTouchPosition = currentPos
        }
        
        lastTouchCount = activeTouchCount
    }
    
    private func handleTouchEnd() {
        guard lastTouchPosition != nil else { return }
        displayDriver.stop()
        
        // Don't trigger tap if physical click button is active
        if cursorController.isClickActive {
            return
        }
        // Don't trigger tap after a multi-finger gesture (e.g. two-finger scroll)
        if hadMultipleFingersInSession {
            return
        }
        
        let duration = Self.machDeltaToSeconds(from: touchStartTime)
        let dx = (lastTouchPosition?.x ?? 0) - touchStartPosition.x
        let dy = (lastTouchPosition?.y ?? 0) - touchStartPosition.y
        let movement = hypot(dx, dy)

        // Swipe detection (flick). Fires before tap check; distance threshold is well above
        // tapMaxDistance, so a swipe can never also register as a tap.
        // In mouse mode, swipes are ignored (trackpad is purely a cursor device).
        if trackpadMode == "gesture" && duration < swipeMaxDuration && movement > swipeMinDistance {
            let absDx = abs(dx), absDy = abs(dy)
            let direction: SwipeDirection?
            if absDx > absDy * swipeAxisRatio {
                direction = dx > 0 ? .right : .left
            } else if absDy > absDx * swipeAxisRatio {
                // MultitouchSupport reports y increasing toward the top of the trackpad.
                direction = dy > 0 ? .up : .down
            } else {
                direction = nil
            }
            if let direction = direction {
                DispatchQueue.main.async { [weak self] in
                    self?.onSwipe?(direction)
                }
                return
            }
        }

        if trackpadMode == "mouse" && duration < tapMaxDuration && movement < tapMaxDistance {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cursorController.performClick()
            }
        }
    }
    
    private func enqueueCursorMovement(deltaX: CGFloat, deltaY: CGFloat) {
        // Start lazily on the first real cursor delta. This also resumes touch
        // movement when a physical Select/gyro hold ends without lifting the finger.
        displayDriver.start()
        let scaledX = deltaX * cursorScale
        let scaledY = -deltaY * cursorScale
        let tuned = cursorController.pointerTunedDelta(deltaX: scaledX, deltaY: scaledY)

        cursorDeltaLock.lock()
        pendingCursorDelta.x += tuned.x
        pendingCursorDelta.y += tuned.y
        cursorDeltaLock.unlock()
    }

    private func renderCursorFrame() {
        cursorDeltaLock.lock()
        let delta = pendingCursorDelta
        pendingCursorDelta = .zero
        cursorDeltaLock.unlock()

        guard !cursorController.isClickActive, delta.x != 0 || delta.y != 0 else { return }
        _ = cursorController.moveCursor(
            deltaX: delta.x,
            deltaY: delta.y,
            applyPointerTuning: false
        )
    }

    private func discardPendingCursorMovement() {
        cursorDeltaLock.lock()
        pendingCursorDelta = .zero
        cursorDeltaLock.unlock()
    }
    
    private func performScroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollX = Int32(-deltaX * scrollScale)
        let scrollY = Int32(deltaY * scrollScale)
        
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: scrollX, deltaY: scrollY)
        }
    }
}

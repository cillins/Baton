//
//  RemoteDetector.swift
//  Baton
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid

/// Hardware generation of a connected Apple Siri Remote. Apple assigns
/// disjoint HID product-ID ranges per physical model — we use that to
/// distinguish gen 1 (trackpad model) from gen 2/3 (clickpad ring model)
/// without BLE/GATT queries. The UI only needs gen1 vs not-gen1 (gen2 covers
/// both Gen 2 and Gen 3 since they look identical externally).
enum Generation: String {
    case gen1   // A1513 — Apple TV 4 (2015), silver touchpad
    case gen2   // A1969 / A2179 / A2540 — Apple TV 4K 1/2/3 代, dark clickpad

    /// Map an Apple vendor HID productID → generation. The productID space is
    /// partially overlap-prone: A1513 (Gen 1) with newer firmware reports
    /// 0x0266, and A1969 / A2179 also use 0x0266–0x0269 across revisions.
    /// Default to Gen 1 for any ID we cannot otherwise place — physical
    /// identification from the model's back-label is authoritative; the UI
    /// surfaces this as the "代际" indicator.
    static func fromProductID(_ pid: Int) -> Generation? {
        switch pid {
        // A1513 (Gen 1) — silver trackpad Siri Remote. Reports 0x0221 on
        // early firmware and 0x0255 / 0x0266 on later firmware revisions of
        // the same hardware.
        case 0x0221, 0x0255, 0x0266:
            return .gen1
        // A1969 / A2179 (Gen 2) and A2540 (Gen 3) — clickpad-ring with
        // discrete arrow buttons. Visually identical from the front.
        case 0x0267, 0x0269,
             0x0C4E, 0x0C4F, 0x030D, 0x030E:
            return .gen2
        default:
            return nil
        }
    }

    /// Wire-format string the JS bridge expects (matches React `dev.art`).
    var wireTag: String { rawValue }
}

/// Append diagnostic line to /tmp/baton.log (unified-log redacts NSLog under hardened runtime).
func rmDebug(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/baton.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

class RemoteDetector {
    private var manager: IOHIDManager?
    private var deviceCallback: ((IOHIDDevice?) -> Void)?
    private var currentDevice: IOHIDDevice?
    /// Last generation value pushed via onGenerationChange. Used to dedupe
    /// callbacks when the same physical remote re-enumerates (the BLE HID
    /// stack fires device-added multiple times for the same remote).
    private var lastGeneration: Generation?
    private var connectedDeviceCount = 0
    // Track devices by vendorID:productID combination
    // A single physical Siri Remote may expose multiple HID interfaces, but we only want to process one
    private var processedDeviceKeys: Set<String> = []
    private let processingQueue = DispatchQueue(label: "com.baton.deviceProcessing")
    
    private let appleVendorID: Int = 0x004C
    
    // Known Siri Remote / Apple TV Remote product IDs
    private let knownProductIDs: [Int] = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269,
        0x0C4E, 0x0C4F, 0x030D, 0x030E
    ]
    
    init(deviceCallback: @escaping (IOHIDDevice?) -> Void) {
        self.deviceCallback = deviceCallback
        self.lastConnectedAt = UserDefaults.standard.object(forKey: Self.lastConnectedAtKey) as? Date
    }
    
    func startDetection() {
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else {
            rmDebug("⚠️ IOHIDManagerCreate returned nil")
            return
        }

        // SiriMote uses IOHIDManagerSetDeviceMatchingMultiple with per-interface dicts.
        // The Siri Remote A1513 exposes 3 HID interfaces (consumer, game controls, vendor),
        // and the singular variant with vendor-only matching does not enumerate them on
        // recent macOS BLE HID stacks.
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],   // Consumer Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],   // Digitizer / Game Controls
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x01],   // Generic Desktop (kept for keyboards/trackpads)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, Unmanaged.passUnretained(self).toOpaque())

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X)", openResult))
            return
        }
        rmDebug("🛰 IOHIDManagerOpen success")

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enumerateAllDevices()
        }
    }
    
    func stopDetection() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        currentDevice = nil
        processedDeviceKeys.removeAll()
        connectedDeviceCount = 0
        deviceCallback?(nil)
    }

    /// Product name of the currently connected device (e.g. "Siri Remote").
    /// Reads kIOHIDProductKey live so the settings window shows the real name.
    var currentDeviceName: String? {
        guard let device = currentDevice else { return nil }
        return IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    }

    /// Hardware generation of the currently connected remote. Derived from the
    /// HID product ID (Apple's vendor 0x004C assigns contiguous ranges per
    /// physical model). Returns nil if not connected or productID unknown.
    var currentGeneration: Generation? {
        guard let device = currentDevice,
              let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        else { return nil }
        return Generation.fromProductID(pid)
    }

    /// Battery level (0-100) populated by `BleBatteryMonitor` from BLE GATT
    /// 0x180F / Battery Level 0x2A19. nil before the first notify (or after
    /// disconnect clears it).
    var currentBattery: Int?

    /// Serial number from kIOHIDSerialNumberKey. Apple does not populate this
    /// property for Bluetooth HID devices in practice, but we read it for
    /// completeness — empty string is treated as "unknown" by the UI.
    var currentSerial: String? {
        guard let device = currentDevice else { return nil }
        return IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    }

    /// Display model name derived from product name + generation. Used as the
    /// "型号" field in the React UI. Examples:
    ///   "Siri Remote（第 1 代）"   for Gen 1
    ///   "Siri Remote（第 2 代）"   for Gen 2
    ///   "Siri Remote"             when generation is unknown
    var currentModel: String {
        let base = currentDeviceName ?? persistedDeviceName ?? "Siri Remote"
        switch currentGeneration ?? persistedGeneration {
        case .gen1: return "\(base)（第 1 代）"
        case .gen2: return "\(base)（第 2 代）"
        case .none: return base
        }
    }

    /// Timestamp of the last successful connection. Persisted to UserDefaults
    /// so it survives app restarts and is shown as "X 天前" while disconnected.
    private static let lastConnectedAtKey = "baton.lastConnectedAt"
    private(set) var lastConnectedAt: Date?

    /// Last resolved hardware generation, persisted so the UI can show the
    /// right remote artwork even when the device is disconnected at launch.
    private static let lastKnownGenerationKey = "baton.lastKnownGeneration"
    var persistedGeneration: Generation? {
        guard let tag = UserDefaults.standard.string(forKey: Self.lastKnownGenerationKey) else { return nil }
        return Generation(rawValue: tag)
    }

    /// Last connected device's product name (includes the user's Bluetooth
    /// rename), persisted so the UI shows it while disconnected.
    private static let lastKnownDeviceNameKey = "baton.lastKnownDeviceName"
    var persistedDeviceName: String? {
        UserDefaults.standard.string(forKey: Self.lastKnownDeviceNameKey)
    }

    /// Fires whenever the connected device's generation changes (including
    /// nil on disconnect). Set by AppDelegate to push state to UI.
    var onGenerationChange: ((Generation?) -> Void)?
    
    private func enumerateAllDevices() {
        guard let manager = manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }
        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                           v, p, pup, pu, n))
            if isSiriRemote(device) {
                handleDeviceAdded(device)
            }
        }
    }
    
    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              vendorID == appleVendorID else { return false }
        
        if let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
           knownProductIDs.contains(productID) {
            return true
        }
        
        if let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            let name = productName.lowercased()
            return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
        }
        
        return false
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        // Create a key based on vendor+product to group all HID interfaces from the same physical device
        // A single Siri Remote may expose multiple HID interfaces (buttons, touch, etc.)
        // but they all share the same vendor and product ID
        let deviceKey = "\(vendorID):\(productID)"
        
        // Use a serialized queue to prevent race conditions when processing devices
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let shouldLog: Bool
            if !self.processedDeviceKeys.contains(deviceKey) {
                // First time seeing this vendor+product combination - log it
                self.processedDeviceKeys.insert(deviceKey)
                self.connectedDeviceCount += 1
                shouldLog = true
            } else {
                // Already seen this vendor+product - skip logging but still process the device
                shouldLog = false
            }
            
            // Always set currentDevice to the latest device (for tracking)
            self.currentDevice = device
            if let name = self.currentDeviceName, !name.isEmpty {
                UserDefaults.standard.set(name, forKey: Self.lastKnownDeviceNameKey)
            }

            // Only log once per physical device (vendor+product combination)
            if shouldLog {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
            }

            // Fire onGenerationChange only when the resolved generation actually
            // differs from the last one we reported — the BLE stack re-emits
            // device-added for every HID interface of the same physical remote.
            let newGen = self.currentGeneration
            rmDebug(String(format: "🛰 gen check: productID=0x%X resolved=%@ last=%@",
                           productID,
                           (newGen?.wireTag as NSString?) ?? "nil" as NSString,
                           (self.lastGeneration?.wireTag as NSString?) ?? "nil" as NSString))
            if newGen != self.lastGeneration {
                self.lastGeneration = newGen
                if let g = newGen {
                    UserDefaults.standard.set(g.wireTag, forKey: Self.lastKnownGenerationKey)
                }
                let cb = self.onGenerationChange
                DispatchQueue.main.async { cb?(newGen) }
                rmDebug("🛰 gen change fired: \(newGen?.wireTag ?? "nil")")
            }

            // Always pass the device to the callback - RemoteInputHandler needs all HID interfaces
            DispatchQueue.main.async {
                self.deviceCallback?(device)
            }
        }
    }
    
    func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        // Create the same key based on vendor+product
        let deviceKey = "\(vendorID):\(productID)"
        
        // Use a serialized queue to prevent race conditions
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Only process removal if we've seen this device before
            guard self.processedDeviceKeys.contains(deviceKey) else { return }
            
            self.processedDeviceKeys.remove(deviceKey)
            self.connectedDeviceCount = max(0, self.connectedDeviceCount - 1)
            
            if self.connectedDeviceCount == 0 {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                print("❌ Siri Remote disconnected: \(productName)")
                // Record the moment we lost the last interface so the UI can
                // render "X 分钟前" until the next reconnect.
                let now = Date()
                self.lastConnectedAt = now
                UserDefaults.standard.set(now, forKey: Self.lastConnectedAtKey)
                self.currentDevice = nil
                if self.lastGeneration != nil {
                    self.lastGeneration = nil
                    let cb = self.onGenerationChange
                    DispatchQueue.main.async { cb?(nil) }
                }
                DispatchQueue.main.async {
                    self.deviceCallback?(nil)
                }
            }
        }
    }
}

// C callbacks
private func deviceAddedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceAdded(device)
}

private func deviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceRemoved(device)
}

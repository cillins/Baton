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
        // A1962 (white ring) reports 0x026D on current macOS BLE HID.
        case 0x0221, 0x0255, 0x0266, 0x026D:
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

    /// Stable UI tag used by the native settings view.
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
    /// Each physical remote exposes several IOHIDDevice interfaces. Track the
    /// interface registry IDs under the physical device UUID so removing one
    /// interface cannot falsely mark the whole remote disconnected. Unlike the
    /// old vendor:product key, the physical UUID also distinguishes two remotes
    /// of the same model.
    private var interfaceIDsByPhysicalKey: [String: Set<UInt64>] = [:]
    private var devicesByInterfaceID: [UInt64: IOHIDDevice] = [:]
    private var currentPhysicalKey: String?
    private let processingQueue = DispatchQueue(label: "com.baton.deviceProcessing")
    
    private let appleVendorID: Int = 0x004C
    
    // Known Siri Remote / Apple TV Remote product IDs
    private let knownProductIDs: [Int] = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269, 0x026D,
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
        if openResult == kIOReturnSuccess {
            rmDebug("🛰 IOHIDManagerOpen success")
        } else {
            // Non-fatal: the Apple-vendor matching dictionaries may include
            // keyboard/trackpad interfaces held by macOS. Matching callbacks
            // and the per-device opens below do not require this broad open.
            rmDebug(String(
                format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X) — continuing with per-device opens",
                openResult
            ))
        }

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
        currentPhysicalKey = nil
        interfaceIDsByPhysicalKey.removeAll()
        devicesByInterfaceID.removeAll()
        deviceCallback?(nil)
    }

    /// Product name of the currently connected device (e.g. "Siri Remote").
    /// Reads kIOHIDProductKey live so the settings window shows the real name.
    var currentDeviceName: String? {
        guard let device = currentDevice else { return nil }
        let rawName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
        if let rawName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawName.isEmpty {
            return rawName
        }
        return productID == 0x026D ? "Siri Remote A1962" : "Siri Remote"
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

    /// Hardware model identifier shown independently from the user-visible
    /// device name. Apple product strings commonly contain values like A1962.
    var currentModel: String {
        let name = currentDeviceName ?? persistedDeviceName
        if let name,
           let range = name.range(of: "A[0-9]{4}", options: .regularExpression) {
            return String(name[range]).uppercased()
        }
        if let device = currentDevice,
           let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
           productID == 0x026D {
            return "A1962"
        }
        return "Siri Remote"
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
            let matches = isSiriRemote(device)
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@ matched=%@",
                           v, p, pup, pu, n, matches ? "yes" : "no"))
            if matches {
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

    /// Stable identity shared by every HID interface of one physical remote.
    /// `PhysicalDeviceUniqueID` is present for BLE HID on current macOS. The
    /// fallbacks keep older firmware working without returning to a plain
    /// vendor/product key that merges same-model remotes.
    private func physicalDeviceKey(for device: IOHIDDevice) -> String {
        if let uuid = IOHIDDeviceGetProperty(
            device, kIOHIDPhysicalDeviceUniqueIDKey as CFString
        ) as? String, !uuid.isEmpty {
            return "physical:\(uuid)"
        }
        if let serial = IOHIDDeviceGetProperty(
            device, kIOHIDSerialNumberKey as CFString
        ) as? String, !serial.isEmpty {
            return "serial:\(serial)"
        }
        if let address = IOHIDDeviceGetProperty(
            device, "DeviceAddress" as CFString
        ) as? String, !address.isEmpty {
            return "address:\(address)"
        }

        // BLE interface LocationIDs are allocated consecutively; subtracting
        // bInterfaceNumber recovers the shared physical base location.
        if let location = IOHIDDeviceGetProperty(
            device, kIOHIDLocationIDKey as CFString
        ) as? Int,
           let interface = IOHIDDeviceGetProperty(
            device, "bInterfaceNumber" as CFString
           ) as? Int {
            return "location-base:\(location - interface)"
        }

        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        return "fallback:\(vendor):\(product):\(name)"
    }

    /// Unique identity for one IOHIDDevice interface. Enumeration and the
    /// matching callback can report the same interface, so registry ID keeps
    /// it from being counted twice.
    private func interfaceRegistryID(for device: IOHIDDevice) -> UInt64 {
        var registryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0,
           IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess {
            return registryID
        }
        return UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private func publishGenerationIfNeeded(_ generation: Generation?, productID: Int?) {
        rmDebug(String(format: "🛰 gen check: productID=%@ resolved=%@ last=%@",
                       productID.map { String(format: "0x%X", $0) } ?? "nil",
                       (generation?.wireTag as NSString?) ?? "nil" as NSString,
                       (lastGeneration?.wireTag as NSString?) ?? "nil" as NSString))
        guard generation != lastGeneration else { return }
        lastGeneration = generation
        if let generation {
            UserDefaults.standard.set(generation.wireTag, forKey: Self.lastKnownGenerationKey)
        }
        let callback = onGenerationChange
        DispatchQueue.main.async { callback?(generation) }
        rmDebug("🛰 gen change fired: \(generation?.wireTag ?? "nil")")
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }
        
        // Get device properties (safe to read from any thread)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        let physicalKey = physicalDeviceKey(for: device)
        let interfaceID = interfaceRegistryID(for: device)
        rmDebug("🛰 queueing interface: registry=0x\(String(interfaceID, radix: 16)) physical=\(physicalKey)")
        
        // Use a serialized queue to prevent race conditions when processing devices
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            var interfaceIDs = self.interfaceIDsByPhysicalKey[physicalKey] ?? []
            let inserted = interfaceIDs.insert(interfaceID).inserted
            guard inserted else { return }
            let isNewPhysicalDevice = interfaceIDs.count == 1
            self.interfaceIDsByPhysicalKey[physicalKey] = interfaceIDs
            self.devicesByInterfaceID[interfaceID] = device

            // Baton controls one active remote. A genuinely new physical UUID
            // takes over; additional interfaces of that remote only enrich the
            // input handler and never create another UI connection.
            if self.currentPhysicalKey == nil || isNewPhysicalDevice {
                self.currentPhysicalKey = physicalKey
            }
            
            // Always set currentDevice to the latest device (for tracking)
            if self.currentPhysicalKey == physicalKey {
                self.currentDevice = device
            }
            if let name = self.currentDeviceName, !name.isEmpty {
                UserDefaults.standard.set(name, forKey: Self.lastKnownDeviceNameKey)
            }

            if isNewPhysicalDevice {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                rmDebug("✅ physical remote connected: \(productName) key=\(physicalKey)")
                print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
            }
            rmDebug("🛰 interface added: registry=0x\(String(interfaceID, radix: 16)) physical=\(physicalKey) count=\(interfaceIDs.count)")

            // Fire onGenerationChange only when the resolved generation actually
            // differs from the last one we reported — the BLE stack re-emits
            // device-added for every HID interface of the same physical remote.
            if self.currentPhysicalKey == physicalKey {
                self.publishGenerationIfNeeded(Generation.fromProductID(productID), productID: productID)
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
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        
        let physicalKey = physicalDeviceKey(for: device)
        let interfaceID = interfaceRegistryID(for: device)
        
        // Use a serialized queue to prevent race conditions
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard var interfaceIDs = self.interfaceIDsByPhysicalKey[physicalKey],
                  interfaceIDs.remove(interfaceID) != nil else { return }
            self.devicesByInterfaceID.removeValue(forKey: interfaceID)

            if !interfaceIDs.isEmpty {
                self.interfaceIDsByPhysicalKey[physicalKey] = interfaceIDs
                if self.currentPhysicalKey == physicalKey, self.currentDevice === device,
                   let replacementID = interfaceIDs.first {
                    self.currentDevice = self.devicesByInterfaceID[replacementID]
                }
                rmDebug("🛰 interface removed: registry=0x\(String(interfaceID, radix: 16)) physical=\(physicalKey) remaining=\(interfaceIDs.count)")
                return
            }

            self.interfaceIDsByPhysicalKey.removeValue(forKey: physicalKey)
            rmDebug("❌ physical remote disconnected: key=\(physicalKey)")

            guard self.currentPhysicalKey == physicalKey else { return }

            if let nextPhysicalKey = self.interfaceIDsByPhysicalKey.keys.first,
               let nextInterfaceID = self.interfaceIDsByPhysicalKey[nextPhysicalKey]?.first,
               let nextDevice = self.devicesByInterfaceID[nextInterfaceID] {
                // Another distinct remote is still connected; switch identity
                // without sending a false disconnected state to the UI.
                self.currentPhysicalKey = nextPhysicalKey
                self.currentDevice = nextDevice
                let nextProductID = IOHIDDeviceGetProperty(
                    nextDevice, kIOHIDProductIDKey as CFString
                ) as? Int
                self.publishGenerationIfNeeded(
                    nextProductID.flatMap(Generation.fromProductID),
                    productID: nextProductID
                )
                DispatchQueue.main.async { self.deviceCallback?(nextDevice) }
            } else {
                let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                print("❌ Siri Remote disconnected: \(productName)")
                // Record the moment we lost the last interface so the UI can
                // render "X 分钟前" until the next reconnect.
                let now = Date()
                self.lastConnectedAt = now
                UserDefaults.standard.set(now, forKey: Self.lastConnectedAtKey)
                self.currentDevice = nil
                self.currentPhysicalKey = nil
                self.publishGenerationIfNeeded(nil, productID: productID)
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

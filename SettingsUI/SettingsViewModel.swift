//
//  SettingsViewModel.swift
//  Baton
//
//  Owns the mirror state for the settings window. Bridges MenuBarManager /
//  RemoteDetector mutations into SwiftUI @Published fields and exposes intent
//  methods that match the old WebBridge protocol 1:1 (so UI code reads like
//  the JS bridge did).
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - VM types (mirror the JSON payload the old bridge sent)

enum Pane: String, CaseIterable, Hashable {
    case overview, buttons, apps, sensitivity
}

struct DeviceState {
    var connected: Bool
    var name: String
    var generation: String   // "gen1" | "gen2" | ""
    var battery: Int          // 0 = unknown
    var model: String
    var lastConnectedAt: Date?
    var version: String
}

struct ButtonOptionVM: Identifiable, Hashable {
    let raw: String
    let label: String
    var id: String { raw }
}

enum MappingEditOptionID {
    static let current = "__current_mapping__"
    static let recordKey = "__record_new_key__"
    static let inputText = "__input_new_text__"
}

struct ButtonRowVM: Identifiable, Hashable {
    let key: String
    let label: String
    let gesture: String
    var action: String
    var customText: String
    var customKey: KeyCombo?
    var options: [ButtonOptionVM]
    var id: String { key }
}

struct SwipeRowVM: Identifiable, Hashable {
    let key: String
    let label: String
    let desc: String
    var action: String
    var customText: String
    var customKey: KeyCombo?
    var options: [ButtonOptionVM]
    var id: String { key }
}

struct ProfileVM: Identifiable, Hashable {
    let id: String
    var name: String
    var builtin: Bool
    var active: Bool
    var trackpadMode: String
}

struct PresetVM: Identifiable, Hashable {
    let id: String          // bundleId
    var bundleId: String
    var appName: String
    var profileId: String
    var icon: NSImage?
}

struct AppVM: Identifiable, Hashable {
    var id: String { bundleId }
    var bundleId: String
    var appName: String
    var icon: NSImage?
}

struct ScrollSpeedOptionVM: Identifiable, Hashable {
    let raw: String
    let label: String
    var id: String { raw }
}

struct KeyCombo: Hashable {
    var keyCode: Int
    var modifiers: [String]   // "cmd","shift","opt","ctrl"
    var label: String
    var systemKeyCode: Int? = nil
}

struct EditMappingsVM {
    let profileId: String
    var name: String
    var builtin: Bool
    var buttons: [ButtonRowVM]
    var swipes: [SwipeRowVM]
    var scrollSpeed: String
    var scrollSpeedOptions: [ScrollSpeedOptionVM]
    var trackpadMode: String
}

// MARK: - ViewModel

final class SettingsViewModel: ObservableObject {

    // Device / hardware state
    @Published var device: DeviceState

    // Mapping state (mirrors WebBridge.pushMappings payload)
    @Published var buttons: [ButtonRowVM] = []
    @Published var swipes: [SwipeRowVM] = []
    @Published var scrollSpeed: String = "Medium"
    @Published var scrollSpeedOptions: [ScrollSpeedOptionVM] = []
    @Published var gyroGain: Double = 2.5
    @Published var gyroSmoothing: Int = 67
    @Published var trackpadSensitivity: Int = 500
    @Published var isSystemOverride: Bool = false
    @Published var profiles: [ProfileVM] = []
    @Published var appPresets: [PresetVM] = []
    @Published var availableApps: [AppVM] = []

    // UI-only state
    @Published var selectedPane: Pane = .overview
    @Published var settingsView: Bool = false
    @Published var editMappings: EditMappingsVM?
    @Published var toast: String?

    // General preferences
    @Published private(set) var launchAtLogin = false
    @Published private(set) var keepRunningWhenClosed = true
    @Published private(set) var showBatteryInMenuBar = false

    // Appearance — read from MB on init, propagated back when user picks in UI.
    @Published var appearance: AppearanceMode = .auto {
        didSet { applyAppearanceToWindow() }
    }

    private weak var menuBarManager: MenuBarManager?
    private weak var remoteDetector: RemoteDetector?

    // Cached last values for partial-update composition, matching what the
    // SettingsWindowController + WebBridge did.
    private var lastConnected: Bool
    private var lastDeviceName: String?
    private var lastGeneration: String?

    private var toastTimer: Timer?

    init(menuBarManager: MenuBarManager, remoteDetector: RemoteDetector?) {
        self.menuBarManager = menuBarManager
        self.remoteDetector = remoteDetector
        self.lastConnected = menuBarManager.isConnected
        self.lastDeviceName = remoteDetector?.currentDeviceName
        self.lastGeneration = remoteDetector?.currentGeneration?.wireTag

        // Initialize device with default values (will be overwritten via updateDevice below).
        self.device = DeviceState(
            connected: menuBarManager.isConnected,
            name: remoteDetector?.currentDeviceName ?? "Siri Remote",
            generation: remoteDetector?.currentGeneration?.wireTag ?? "",
            battery: remoteDetector?.currentBattery ?? 0,
            model: remoteDetector?.currentModel ?? "Siri Remote",
            lastConnectedAt: remoteDetector?.lastConnectedAt,
            version: Self.cachedAppVersion()
        )

        // Pull persisted appearance from UserDefaults — the menu-bar popover
        // path writes it back via menuBarManager.onAppearanceChange.
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearance = mode
        }

        launchAtLogin = LoginItemManager.isEnabled
        keepRunningWhenClosed = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.keepRunningWhenClosed
        )
        showBatteryInMenuBar = UserDefaults.standard.bool(
            forKey: AppPreferenceKey.showBatteryInMenuBar
        )
        menuBarManager.setShowsBatteryPercentage(showBatteryInMenuBar)

        // Cache a single mutation callback so the VM gets fresh state when the
        // active profile flips (manual switch or app-activation binding).
        menuBarManager.onCurrentProfileChange = { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        menuBarManager.onAppearanceChange = { [weak self] ap in
            DispatchQueue.main.async {
                if let mode = AppearanceMode(rawValue: ap) { self?.appearance = mode }
            }
        }

        // Initial population.
        reload()
        if let gen = remoteDetector?.currentGeneration {
            updateDevice(connected: menuBarManager.isConnected,
                         deviceName: remoteDetector?.currentDeviceName,
                         generation: gen.wireTag)
        }
        scanInstalledApps()
        applyAppearanceToWindow()
    }

    // MARK: - Reload (rebuild from MenuBarManager)

    func reload() {
        guard let mgr = menuBarManager else { return }
        let currentActionForButton: (String) -> String = { mgr.getMapping(for: $0).rawValue }
        let currentActionForSwipe: (SwipeDirection) -> String = { mgr.getSwipeMapping(for: $0).rawValue }

        self.buttons = MenuBarManager.buttonRows.map { row in
            let text = mgr.customText(forButton: row.key)
            let combo = mgr.customKeyCombo(forButton: row.key)
            let action = currentActionForButton(row.key)
            return ButtonRowVM(
                key: row.key,
                label: row.label,
                gesture: row.gesture,
                action: action,
                customText: text ?? "",
                customKey: combo.flatMap(Self.keyComboFromDict),
                options: Self.optionsForButton(action: action, text: text, combo: combo)
            )
        }

        let swipeMeta: [(SwipeDirection, String, String)] = [
            (.up,    "上滑", "单指向上轻扫"),
            (.down,  "下滑", "单指向下轻扫"),
            (.left,  "左滑", "单指向左轻扫"),
            (.right, "右滑", "单指向右轻扫"),
        ]
        self.swipes = swipeMeta.map { (dir, label, desc) in
            let text = mgr.customText(forSwipe: dir)
            let combo = mgr.customKeyCombo(forSwipe: dir)
            let action = currentActionForSwipe(dir)
            return SwipeRowVM(
                key: dir.rawValue,
                label: label,
                desc: desc,
                action: action,
                customText: text ?? "",
                customKey: combo.flatMap(Self.keyComboFromDict),
                options: Self.optionsForSwipe(action: action, text: text, combo: combo)
            )
        }

        self.scrollSpeed = mgr.scrollSpeed.rawValue
        self.scrollSpeedOptions = ScrollSpeed.allCases.map {
            ScrollSpeedOptionVM(raw: $0.rawValue, label: $0.displayName)
        }
        self.gyroGain = mgr.gyroGain
        self.gyroSmoothing = mgr.gyroSmoothing
        self.trackpadSensitivity = mgr.trackpadSensitivity
        self.isSystemOverride = mgr.isSystemOverride
        self.profiles = mgr.profiles.map { p in
            ProfileVM(id: p.id, name: p.name, builtin: p.builtin,
                      active: p.id == mgr.currentProfileId, trackpadMode: p.trackpadMode)
        }
        self.appPresets = mgr.appPresets.map { a in
            var icon: NSImage? = nil
            if let data = a.iconData { icon = NSImage(data: data) }
            return PresetVM(id: a.bundleId, bundleId: a.bundleId, appName: a.appName,
                            profileId: a.profileId, icon: icon)
        }
    }

    /// Reload only the edit-modal mappings for a profile (doesn't activate it).
    func reloadEdit(profileId: String) {
        guard let mgr = menuBarManager,
              let p = mgr.profiles.first(where: { $0.id == profileId }) else { return }

        let buttons: [ButtonRowVM] = MenuBarManager.buttonRows.map { row in
            let action = p.buttonMappings[row.key] ?? .none
            let text = mgr.customText(forButton: row.key)
            let combo = mgr.customKeyCombo(forButton: row.key)
            return ButtonRowVM(
                key: row.key, label: row.label, gesture: row.gesture,
                action: action.rawValue,
                customText: text ?? "",
                customKey: combo.flatMap(Self.keyComboFromDict),
                options: Self.optionsForButton(action: action.rawValue, text: text, combo: combo)
            )
        }

        let swipeMeta: [(SwipeDirection, String, String)] = [
            (.up,    "上滑", "单指向上轻扫"),
            (.down,  "下滑", "单指向下轻扫"),
            (.left,  "左滑", "单指向左轻扫"),
            (.right, "右滑", "单指向右轻扫"),
        ]
        let swipes: [SwipeRowVM] = swipeMeta.map { (dir, label, desc) in
            let action = p.swipeMappings[dir.rawValue] ?? .none
            let text = mgr.customText(forSwipe: dir)
            let combo = mgr.customKeyCombo(forSwipe: dir)
            return SwipeRowVM(
                key: dir.rawValue, label: label, desc: desc,
                action: action.rawValue,
                customText: text ?? "",
                customKey: combo.flatMap(Self.keyComboFromDict),
                options: Self.optionsForSwipe(action: action.rawValue, text: text, combo: combo)
            )
        }

        self.editMappings = EditMappingsVM(
            profileId: profileId,
            name: p.name,
            builtin: p.builtin,
            buttons: buttons,
            swipes: swipes,
            scrollSpeed: mgr.scrollSpeed.rawValue,
            scrollSpeedOptions: ScrollSpeed.allCases.map {
                ScrollSpeedOptionVM(raw: $0.rawValue, label: $0.displayName)
            },
            trackpadMode: p.trackpadMode
        )
    }

    // MARK: - Device updates (called by AppDelegate via controller)

    func attachRemoteDetector(_ detector: RemoteDetector) {
        remoteDetector = detector
        lastDeviceName = detector.currentDeviceName ?? lastDeviceName
        lastGeneration = detector.currentGeneration?.wireTag ?? lastGeneration
        updateDevice(
            connected: menuBarManager?.isConnected ?? device.connected,
            deviceName: detector.currentDeviceName,
            generation: detector.currentGeneration?.wireTag,
            battery: detector.currentBattery
        )
    }

    func updateDevice(connected: Bool, deviceName: String?, generation: String? = nil,
                      battery: Int? = nil) {
        // When only a subset of fields arrive, fill the rest from the detector
        // (mirrors SettingsWindowController.pushState behavior).
        let detector = remoteDetector
        lastConnected = connected
        lastDeviceName = deviceName ?? lastDeviceName
        if let g = generation, !g.isEmpty { lastGeneration = g }
        let version = Self.cachedAppVersion()
        let model = detector?.currentModel ?? device.model
        let lastAt = detector?.lastConnectedAt ?? device.lastConnectedAt
        let resolvedName = deviceName ?? detector?.persistedDeviceName ?? lastDeviceName ?? device.name
        let resolvedGen = lastGeneration ?? detector?.persistedGeneration?.wireTag ?? ""
        // Connection and generation callbacks are partial updates. Preserve a
        // valid GATT battery reading instead of resetting it to 0 whenever one
        // of those unrelated callbacks arrives.
        let resolvedBatt = battery ?? detector?.currentBattery ?? device.battery

        self.device = DeviceState(
            connected: connected,
            name: resolvedName,
            generation: resolvedGen,
            battery: resolvedBatt,
            model: model,
            lastConnectedAt: lastAt,
            version: version
        )
    }

    func updateBattery(_ battery: Int?) {
        device = DeviceState(
            connected: device.connected,
            name: device.name,
            generation: device.generation,
            battery: battery ?? 0,
            model: device.model,
            lastConnectedAt: device.lastConnectedAt,
            version: device.version
        )
    }

    // MARK: - Intents (1:1 with old WebBridge handler cases)

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            launchAtLogin = LoginItemManager.isEnabled
            if LoginItemManager.requiresApproval {
                showToast("已添加登录项，请在“系统设置 → 通用 → 登录项”中允许")
            } else {
                showToast(enabled ? "已开启登录时启动" : "已关闭登录时启动")
            }
        } catch {
            launchAtLogin = LoginItemManager.isEnabled
            showToast("无法修改登录项：\(error.localizedDescription)")
        }
    }

    func setKeepRunningWhenClosed(_ enabled: Bool) {
        keepRunningWhenClosed = enabled
        UserDefaults.standard.set(enabled, forKey: AppPreferenceKey.keepRunningWhenClosed)
    }

    func setShowBatteryInMenuBar(_ enabled: Bool) {
        showBatteryInMenuBar = enabled
        menuBarManager?.setShowsBatteryPercentage(enabled)
    }

    func openHelp() {
        guard let url = URL(string: "https://github.com/cillins/Baton") else { return }
        NSWorkspace.shared.open(url)
    }

    func setProfileMapping(profileId: String, target: String, key: String, actionRaw: String) {
        menuBarManager?.setProfileMapping(profileId: profileId, target: target, key: key, actionRaw: actionRaw)
        reload()
        // If the edit modal is open for this profile, refresh it too so the row's
        // picker reflects the new selection immediately.
        if editMappings?.profileId == profileId {
            reloadEdit(profileId: profileId)
        }
    }

    func setScrollSpeed(_ raw: String) {
        if let speed = ScrollSpeed(rawValue: raw) {
            menuBarManager?.setScrollSpeed(speed)
            reload()
        }
    }

    func setGyro(gain: Double, smoothing: Int) {
        menuBarManager?.setGyroSettings(gain: gain, smoothing: smoothing)
        reload()
    }

    func setTrackpadSensitivity(_ value: Int) {
        menuBarManager?.setTrackpadSensitivity(value)
        reload()
    }

    func setCustomText(target: String, key: String, text: String) {
        if target == "button" {
            menuBarManager?.setCustomText(forButton: key, text: text)
        } else if let dir = SwipeDirection(rawValue: key) {
            menuBarManager?.setCustomText(forSwipe: dir, text: text)
        }
        reload()
        if let pid = editMappings?.profileId { reloadEdit(profileId: pid) }
    }

    func setCustomKey(target: String, key: String, combo: KeyCombo) {
        var dict: [String: Any] = [
            "keyCode": combo.keyCode,
            "modifiers": combo.modifiers,
            "label": combo.label,
        ]
        if let systemKeyCode = combo.systemKeyCode {
            dict["systemKeyCode"] = systemKeyCode
        }
        if target == "button" {
            menuBarManager?.setCustomKeyCombo(forButton: key, combo: dict)
        } else if let dir = SwipeDirection(rawValue: key) {
            menuBarManager?.setCustomKeyCombo(forSwipe: dir, combo: dict)
        }
        reload()
        if let pid = editMappings?.profileId { reloadEdit(profileId: pid) }
    }

    func selectProfile(_ id: String) {
        menuBarManager?.selectProfile(id: id)
        // selectProfile fires onCurrentProfileChange which calls reload().
    }

    func createProfile(name: String) -> String? {
        guard let mgr = menuBarManager else { return nil }
        let id = mgr.createProfile(name: name)
        reload()
        return id
    }

    func deleteProfile(_ id: String) {
        menuBarManager?.deleteProfile(id: id)
        reload()
    }

    func renameProfile(_ id: String, name: String) {
        menuBarManager?.renameProfile(id: id, name: name)
        reload()
    }

    func resetProfile(_ id: String) {
        menuBarManager?.resetProfileToDefault(profileId: id)
        reload()
    }

    func setTrackpadMode(profileId: String, mode: String) {
        menuBarManager?.setTrackpadMode(profileId: profileId, mode: mode)
        reload()
        if editMappings?.profileId == profileId { reloadEdit(profileId: profileId) }
    }

    func addAppPreset(bundleId: String, appName: String, profileId: String, iconData: Data?) {
        menuBarManager?.addAppPreset(bundleId: bundleId, appName: appName,
                                     profileId: profileId, iconData: iconData)
        reload()
    }

    func removeAppPreset(_ bundleId: String) {
        menuBarManager?.removeAppPreset(bundleId: bundleId)
        reload()
    }

    func setAppPresetProfile(bundleId: String, profileId: String) {
        menuBarManager?.setAppPresetProfile(bundleId: bundleId, profileId: profileId)
        reload()
    }

    func openEdit(profileId: String) {
        reloadEdit(profileId: profileId)
    }

    func closeEdit() {
        editMappings = nil
    }

    // MARK: - Toast

    func showToast(_ message: String, duration: TimeInterval = 2.8) {
        toastTimer?.invalidate()
        toast = message
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.toast = nil }
        }
    }

    // MARK: - App scan

    func scanInstalledApps() {
        let dirs = ["/Applications", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var seen: Set<String> = []
            var apps: [AppVM] = []
            for dir in dirs {
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let path = (dir as NSString).appendingPathComponent(entry)
                    guard let infoPlist = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Contents/Info.plist")),
                          let bid = infoPlist["CFBundleIdentifier"] as? String,
                          let name = infoPlist["CFBundleName"] as? String,
                          !seen.contains(bid) else { continue }
                    seen.insert(bid)
                    let img = NSWorkspace.shared.icon(forFile: path)
                    apps.append(AppVM(bundleId: bid, appName: name, icon: img))
                }
            }
            apps.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            DispatchQueue.main.async {
                self?.availableApps = apps
            }
        }
    }

    // MARK: - Appearance

    private func applyAppearanceToWindow() {
        // Apply the choice at application level so every Baton window and
        // popover resolves the same appearance. .auto restores system flow.
        UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode")
        NSApp.appearance = appearance.nsAppearance
        NSApp.windows.forEach { $0.appearance = appearance.nsAppearance }
    }

    // MARK: - Helpers

    /// JS-recorded glyphs use Unicode chars that don't match Mac keyboard reality.
    /// Same normalization MenuBarManager uses for its own customKey display.
    static func keyComboFromDict(_ d: [String: Any]) -> KeyCombo? {
        guard let keyCode = d["keyCode"] as? Int,
              let modifiers = d["modifiers"] as? [String] else { return nil }
        let label = (d["label"] as? String).map {
            MenuBarManager.customKeyGlyphNormalization[$0] ?? $0
        } ?? ""
        return KeyCombo(keyCode: keyCode, modifiers: modifiers, label: label,
                        systemKeyCode: d["systemKeyCode"] as? Int)
    }

    /// Mapping menus are compact editors, not action catalogs. The first item
    /// mirrors the current persisted action; the other two open the existing
    /// inline editors for replacing it with a recorded key or typed text.
    private static func optionsForButton(action: String, text: String?, combo: [String: Any]?) -> [ButtonOptionVM] {
        let base = ButtonAction(rawValue: action)?.displayName ?? action
        return editingOptions(
            currentLabel: customOptionLabel(base: base, raw: action, text: text, combo: combo)
        )
    }

    private static func optionsForSwipe(action: String, text: String?, combo: [String: Any]?) -> [ButtonOptionVM] {
        let base = SwipeAction(rawValue: action)?.displayName ?? action
        return editingOptions(
            currentLabel: customOptionLabel(base: base, raw: action, text: text, combo: combo)
        )
    }

    private static func editingOptions(currentLabel: String) -> [ButtonOptionVM] {
        [
            ButtonOptionVM(raw: MappingEditOptionID.current, label: currentLabel),
            ButtonOptionVM(raw: MappingEditOptionID.recordKey, label: "录制新按键"),
            ButtonOptionVM(raw: MappingEditOptionID.inputText, label: "输入新文本"),
        ]
    }

    /// Custom actions use the same display logic as the menu-bar picker: once
    /// configured, show only the payload ("/compact" / "⌘⇧P") like any other
    /// action label. The inline editor below the row already communicates that
    /// the action is custom, so repeating that prefix here adds visual noise.
    private static func customOptionLabel(base: String, raw: String, text: String?, combo: [String: Any]?) -> String {
        switch raw {
        case ButtonAction.customText.rawValue:
            return MenuBarManager.customTextDisplayLabel(text, fallback: base)
        case ButtonAction.customKey.rawValue:
            guard let combo else { return base }
            return MenuBarManager.customKeyDisplayLabel(combo: combo, fallback: base)
        default:
            return base
        }
    }

    // MARK: - App version (cached — Bundle lookup is cheap but called on every reload)

    private static var cachedVersion: String?
    private static func cachedAppVersion() -> String {
        if let v = cachedVersion { return v }
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        let s = "\(v) (\(b))"
        cachedVersion = s
        return s
    }
}

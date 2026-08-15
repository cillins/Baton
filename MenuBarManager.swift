//
//  MenuBarManager.swift
//  Baton
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable, Codable {
    case enterKey = "Enter: Submit prompt"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case leftKey = "Left: Navigate Left"
    case rightKey = "Right: Navigate Right"
    case bKey = "B: Black Screen"
    case wKey = "W: White Screen"
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case remoteMicrophone = "Siri Remote: Virtual Microphone"
    case mediaPlayPause = "Media: Play/Pause"
    case mediaNext = "Media: Next Track"
    case mediaPrev = "Media: Previous Track"
    case mediaMute = "Media: Mute Toggle"
    case systemVolumeUp = "System Volume: Up"
    case systemVolumeDown = "System Volume: Down"
    case presentation = "Presentation: Start Fullscreen"
    case trackpadClick = "Mouse Click"
    case customText = "Custom Text"
    case customKey = "Custom Key"
    case none = "None"

    /// Push-to-talk dictation needs the virtual key held for the full press duration.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// only offered for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt, .remoteMicrophone: return true
        default: return false
        }
    }

    /// Menu display name. rawValue stays English: it's the UserDefaults persistence
    /// key and round-trips through executeAction(_:), so it must remain stable.
    var displayName: String {
        switch self {
        case .enterKey:         return "⏎"        // Mac Return key symbol
        case .upKey:            return "↑"
        case .downKey:          return "↓"
        case .leftKey:          return "←"
        case .rightKey:         return "→"
        case .bKey:             return "B"
        case .wKey:             return "W"
        case .escKey:           return "esc"       // Mac Esc key labels "esc"
        case .ctrlC:            return "⌃C"
        case .spaceKey:         return "␣"
        case .rightCmd:         return "⌘"         // ⌘ is on the Cmd key
        case .rightOpt:         return "⌥"
        case .remoteMicrophone: return "🎙"
        case .mediaPlayPause:   return "⏯"
        case .mediaNext:        return "⏭"
        case .mediaPrev:        return "⏮"
        case .mediaMute:        return "🔇"
        case .systemVolumeUp:   return "音量+"
        case .systemVolumeDown: return "音量−"
        case .presentation:     return "⌥⌘P"
        case .trackpadClick:    return "Click"     // no keyboard symbol for this
        case .customText:       return "Text"      // placeholder, replaced when bound
        case .customKey:        return "Key"       // placeholder, replaced when bound
        case .none:             return "—"
        }
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0) — verified via /tmp/baton.log.
/// menu/tv/select are excluded: menu/tv are press-only on the Siri Remote, select is handled separately for click/drag.
let holdCapableButtons: Set<String> = ["playPause", "volumeUp", "volumeDown", "siri"]

/// Trackpad swipe directions (single-finger flicks). Detection happens in TouchHandler;
/// execution is dispatched here so mappings live alongside button mappings.
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// Action a swipe can trigger. Slash-command cases type the raw value (without Enter — user
/// presses Enter themselves). `leftArrow`/`rightArrow` send virtual arrow keys instead of text.
/// `init` is a Swift keyword so the case name is backtick-escaped; rawValue "/init" is what displays.
enum SwipeAction: String, CaseIterable, Codable {
    // Priority order: direction-matched arrows (filtered per submenu), then Mode Switching,
    // then ultrathink, then slash commands alphabetically, None last.
    case upArrow       = "Up: Navigate Up"
    case downArrow     = "Down: Navigate Down"
    case leftArrow     = "Left: Navigate Left"
    case rightArrow    = "Right: Navigate Right"
    case modeSwitch    = "Mode Switching (Shift + Tab)"
    case bKey          = "B: Black Screen"
    case wKey          = "W: White Screen"
    case mediaPlayPause = "Media: Play/Pause"
    case mediaNext     = "Media: Next Track"
    case mediaPrev     = "Media: Previous Track"
    case mediaMute     = "Media: Mute Toggle"
    case ultrathink    = "ultrathink"
    case btw           = "/btw"
    case compact       = "/compact"
    case config        = "/config"
    case context       = "/context"
    case effort        = "/effort"
    case `init`        = "/init"
    case model         = "/model"
    case remoteControl = "/remote-control"
    case schedule      = "/schedule"
    case tasks         = "/tasks"
    case usage         = "/usage"
    case customText    = "Custom Text"
    case customKey     = "Custom Key"
    case none          = "None"

    /// Menu display name. Slash commands and keywords show their rawValue — that's the
    /// literal text typed into the prompt, so it doubles as the label.
    var displayName: String {
        switch self {
        case .upArrow:     return "↑"
        case .downArrow:   return "↓"
        case .leftArrow:   return "←"
        case .rightArrow:  return "→"
        case .modeSwitch:  return "⇧⇥"
        case .bKey:        return "B"
        case .wKey:        return "W"
        case .mediaPlayPause: return "⏯"
        case .mediaNext:   return "⏭"
        case .mediaPrev:   return "⏮"
        case .mediaMute:   return "🔇"
        case .customText:  return "Text"
        case .customKey:   return "Key"
        case .none:        return "—"
        default:           return rawValue   // slash commands
        }
    }
}

// Scroll speed options
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }

    var displayName: String {
        switch self {
        case .slow: return "慢"
        case .medium: return "中"
        case .fast: return "快"
        }
    }
}

// MARK: - Per-app profiles
//
// Profile = a named snapshot of button + swipe mappings. AppPreset binds an
// installed app's bundleId to a profile; MenuBarManager flips to the bound
// profile when that app becomes frontmost (NSWorkspace observer in AppDelegate).
// Persisted as Codable JSON in UserDefaults.

struct Profile: Codable, Equatable {
    let id: String
    var name: String
    var builtin: Bool
    var buttonMappings: [String: ButtonAction]   // keys per MenuBarManager.buttonRows
    var swipeMappings: [String: SwipeAction]     // keys: "up"/"down"/"left"/"right"
    /// "mouse" = cursor control only; "gesture" = swipe shortcuts only (no cursor).
    var trackpadMode: String
    var scrollSpeed: String

    enum CodingKeys: String, CodingKey {
        case id, name, builtin, buttonMappings, swipeMappings, trackpadMode, scrollSpeed
    }

    init(id: String, name: String, builtin: Bool,
         buttonMappings: [String: ButtonAction], swipeMappings: [String: SwipeAction],
         trackpadMode: String = "mouse", scrollSpeed: String = ScrollSpeed.medium.rawValue) {
        self.id = id; self.name = name; self.builtin = builtin
        self.buttonMappings = buttonMappings; self.swipeMappings = swipeMappings
        self.trackpadMode = trackpadMode
        self.scrollSpeed = scrollSpeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        builtin = try c.decode(Bool.self, forKey: .builtin)
        buttonMappings = try c.decode([String: ButtonAction].self, forKey: .buttonMappings)
        swipeMappings = try c.decode([String: SwipeAction].self, forKey: .swipeMappings)
        trackpadMode = try c.decodeIfPresent(String.self, forKey: .trackpadMode) ?? "mouse"
        scrollSpeed = try c.decodeIfPresent(String.self, forKey: .scrollSpeed)
            ?? UserDefaults.standard.string(forKey: "scrollSpeed")
            ?? ScrollSpeed.medium.rawValue
    }
}

struct AppPreset: Codable, Equatable {
    let bundleId: String
    var appName: String
    var profileId: String
    /// PNG bytes for the app icon (smaller copy, e.g. 64px). Optional because
    /// some bundles have no extractable icon.
    var iconData: Data?
}

class MenuBarManager {

    /// The JS-side key recorder emits labels in glyph form, but two of them
    /// diverge from what the Mac keyboard actually prints on the key:
    ///   - "↩" (Unicode ENTER) vs Mac Return key ⏎
    ///   - "⎋" (Unicode BROKEN CIRCLE) vs Mac Esc key text "esc"
    /// Normalize so a customKey binding displays identically to the preset
    /// action that does the same thing.
    static let customKeyGlyphNormalization: [String: String] = [
        "↩": "⏎",
        "⎋": "esc",
    ]
    static func customKeyDisplayLabel(combo: [String: Any], fallback: String) -> String {
        guard let label = combo["label"] as? String, !label.isEmpty else { return fallback }
        return customKeyGlyphNormalization[label] ?? label
    }

    static func customTextDisplayLabel(_ text: String?, fallback: String) -> String {
        guard let text, !text.isEmpty else { return fallback }
        return text.count > 12 ? String(text.prefix(12)) + "…" : text
    }

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private var currentBatteryLevel: Int?
    private var showsBatteryPercentage = UserDefaults.standard.bool(
        forKey: AppPreferenceKey.showBatteryInMenuBar
    )
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: ButtonAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: SwipeAction] = [:]

    // Custom action payloads, keyed by profile id + button key / swipe direction.
    // Key combo dict: {"keyCode": Int, "modifiers": ["cmd","shift","opt","ctrl"],
    // "label": "⌘⇧P", optional "systemKeyCode": Int for NX_SYSDEFINED keys}.
    private var customButtonTexts: [String: String] = [:]
    private var customButtonKeys: [String: [String: Any]] = [:]
    private var customSwipeTexts: [String: String] = [:]
    private var customSwipeKeys: [String: [String: Any]] = [:]
    private static let customPayloadSeparator = "::"
    private var remoteMicrophoneHoldKey: [String: Any]?

    private static let defaultSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .upArrow,
        .down:  .downArrow,
        .left:  .leftArrow,
        .right: .rightArrow,
    ]

    private static let defaultButtonMappings: [String: ButtonAction] = [
        "playPause": .enterKey,
        "menu": .escKey,
        "select": .trackpadClick,
        "volumeUp": .systemVolumeUp,
        "volumeDown": .systemVolumeDown,
        "siri": .remoteMicrophone,
        "tv": .none
    ]

    /// Claude Code coding profile — slash commands and coding-specific inputs.
    private static let codingSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .usage,
        .down:  .compact,
        .left:  .model,
        .right: .modeSwitch,
    ]

    private static let codingButtonMappings: [String: ButtonAction] = [
        "playPause": .enterKey,
        "menu": .escKey,
        "select": .trackpadClick,
        "volumeUp": .none,
        "volumeDown": .none,
        "siri": .remoteMicrophone,
        "tv": .none
    ]

    /// PPT-presentation centered profile (gen-1 remote). Menu = start fullscreen;
    /// Siri / volume+ = previous slide; playPause / volume- = next slide; TV = exit.
    private static let demoButtonMappings: [String: ButtonAction] = [
        "select":     .trackpadClick,
        "menu":       .presentation,
        "tv":         .none,
        "siri":       .leftKey,
        "playPause":  .rightKey,
        "volumeUp":   .leftKey,
        "volumeDown": .rightKey,
    ]

    private static let demoSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .bKey,
        .down:  .wKey,
        .left:  .leftArrow,
        .right: .rightArrow,
    ]

    /// Media-playback centered profile. HID path is the source of truth — it synthesizes
    /// NX_SYSDEFINED via mediaController so the playing app receives one event per press.
    /// Volume buttons map to .none so the underlying AVRCP absolute-volume path reaches
    /// coreaudiod; `VolumeRevertGuard.shouldArmForRemoteButton` is gated off in this profile
    /// so the change persists.
    private static let mediaButtonMappings: [String: ButtonAction] = [
        "select":     .trackpadClick,
        "menu":       .mediaPrev,
        "tv":         .none,
        "siri":       .mediaMute,
        "playPause":  .mediaPlayPause,
        "volumeUp":   .none,
        "volumeDown": .none,
    ]

    private static let mediaSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .mediaNext,
        .down:  .mediaPrev,
        .left:  .mediaPrev,
        .right: .mediaNext,
    ]

    /// Mappable buttons in display order, shared by the menu bar and the settings
    /// window. gesture is a cosmetic label for the window's 手势 column.
    static let buttonRows: [(key: String, label: String, gesture: String)] = [
        ("select",     "触控板按下",  "单击"),
        ("menu",       "Menu 键",    "单击"),
        ("siri",       "Siri 键",    "按住"),
        ("playPause",  "播放/暂停键", "单击"),
        ("volumeUp",   "音量加",     "单击"),
        ("volumeDown", "音量减",     "单击"),
    ]

    /// Actions offered for a button: hold-to-talk actions only on buttons that
    /// emit release events; Mouse Click only on the trackpad click.
    /// Used by the native settings view model to populate
    /// the per-row dropdown — not by the menu bar picker, which shows the 4 fixed
    /// entries built inline in rebuildMenu().
    static func availableActions(forButton key: String) -> [ButtonAction] {
        ButtonAction.allCases.filter { action in
            if action.requiresHold && !holdCapableButtons.contains(key) { return false }
            if action == .trackpadClick && key != "select" { return false }
            return true
        }
    }

    /// Swipe actions offered for a direction: arrow keys only on their matching direction.
    static func availableSwipeActions(for direction: SwipeDirection) -> [SwipeAction] {
        SwipeAction.allCases.filter { action in
            if action == .upArrow && direction != .up { return false }
            if action == .downArrow && direction != .down { return false }
            if action == .leftArrow && direction != .left { return false }
            if action == .rightArrow && direction != .right { return false }
            return true
        }
    }

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    // Gyro drag feel (gen-1 hold-select wand). gain: raw units → px/s multiplier.
    // smoothing: 0-100 user-facing strength; converted to One Euro minCutoff.
    private(set) var gyroGain: Double = 2.5
    private(set) var gyroSmoothing: Int = 67

    /// One Euro minCutoff for the given smoothing strength: higher strength →
    /// lower cutoff → heavier smoothing. The previous 0.2...2.0 range added
    /// too much phase lag; 0.8...5.0 keeps steady aim smooth without feeling
    /// detached. The default 67% resolves to about 2.19 Hz.
    var gyroMinCutoff: Double { 5.0 - Double(gyroSmoothing) / 100.0 * 4.2 }

    // Trackpad cursor sensitivity (TouchHandler cursorScale; 500 = default).
    private(set) var trackpadSensitivity: Int = 500

    // Per-app profiles + app→profile bindings. Persisted separately from the
    // runtime buttonMappings/swipeMappings; runtime values are the active
    // profile's mappings mirrored onto buttonMappings/swipeMappings for menu +
    // RemoteInputHandler to read unchanged.
    private(set) var profiles: [Profile] = []
    private(set) var appPresets: [AppPreset] = []
    private(set) var currentProfileId: String = "default"

    /// Set by AppDelegate; fired when the active profile changes (manual switch
    /// or app activation binding match). The settings window refetches state
    /// in response so the per-row action labels stay in sync.
    var onCurrentProfileChange: ((String) -> Void)?

    /// Set by AppDelegate; fired when the active profile's trackpadMode changes.
    /// The TouchHandler switches between cursor and gesture-only behaviour.
    var onTrackpadModeChange: ((String) -> Void)?

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    /// Set by AppDelegate; fired whenever connection state flips so the settings
    /// window can refresh its live status row.
    var onConnectionChange: ((Bool) -> Void)?

    /// Set by AppDelegate; fired when scroll speed changes via the settings window.
    var onScrollSpeedChange: ((ScrollSpeed) -> Void)?

    /// Set by AppDelegate; fired when gyro settings change via the settings window.
    var onGyroSettingsChange: (() -> Void)?

    /// Set by AppDelegate; fired when trackpad sensitivity changes via the settings window.
    var onTrackpadSensitivityChange: ((Int) -> Void)?

    /// Set by AppDelegate; fired when the user picks "打开主窗口…" from the menu.
    var onOpenSettings: (() -> Void)?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "状态：未连接", action: nil, keyEquivalent: "")

        loadMappings()
        loadSwipeMappings()
        loadScrollSpeed()
        loadGyroSettings()
        loadTrackpadSensitivity()
        loadProfiles()
        loadCustomPayloads()
        loadAppPresets()
        setupMenuBar()
    }
    
    private func loadMappings() {
        let defaultMappings = Self.defaultButtonMappings

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        //   v5: default volume buttons explicitly map to system volume up/down
        //   v6: Siri's factory mapping now drives the A1962 virtual microphone
        let currentSchema = 6
        let savedSchema = UserDefaults.standard.integer(forKey: "buttonMappingsSchema")
        if savedSchema < 3 {
            UserDefaults.standard.removeObject(forKey: "buttonMappings")
        } else if savedSchema < 4 {
            // Targeted migration: reset "select" so the new default applies, preserve others.
            if var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
                saved.removeValue(forKey: "select")
                UserDefaults.standard.set(saved, forKey: "buttonMappings")
            }
        }
        if savedSchema >= 4 && savedSchema < 5,
           var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            // Only replace the old factory value. Preserve an explicit custom
            // mapping if the user already assigned either volume button.
            if saved["volumeUp"] == ButtonAction.none.rawValue {
                saved.removeValue(forKey: "volumeUp")
            }
            if saved["volumeDown"] == ButtonAction.none.rawValue {
                saved.removeValue(forKey: "volumeDown")
            }
            UserDefaults.standard.set(saved, forKey: "buttonMappings")
        }
        if savedSchema >= 5 && savedSchema < 6,
           var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String],
           saved["siri"] == ButtonAction.spaceKey.rawValue {
            saved.removeValue(forKey: "siri")
            UserDefaults.standard.set(saved, forKey: "buttonMappings")
        }
        if savedSchema < currentSchema {
            UserDefaults.standard.set(currentSchema, forKey: "buttonMappingsSchema")
        }

        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            for (button, actionRaw) in saved {
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings where action.requiresHold && !holdCapableButtons.contains(button) {
                buttonMappings[button] = ButtonAction.none
            }
        } else {
            buttonMappings = defaultMappings
            saveMappings()
        }
    }
    
    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
    }
    
    /// Loads the user-designed Siri Remote menu-bar icon from `Resources/`.
    /// NSImage auto-resolves `@2x` on retina; falls back to a 1×1 transparent
    /// image if the asset is missing (e.g., during dev with no bundle yet).
    /// `isTemplate = true` lets AppKit tint the silhouette with the menu bar's
    /// foreground color, so the icon adapts to light/dark menu bars automatically.
    private static func makeRemoteIcon() -> NSImage {
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            return img
        }
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.makeRemoteIcon()
        renderStatusItemButton()

        rebuildMenu()
        statusItem.menu = menu
    }

    /// Set by AppDelegate; fired when the user picks a new appearance in the settings UI.
    var onAppearanceChange: ((String) -> Void)?

    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Siri 遥控器", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())

        // Open main window
        let openItem = NSMenuItem(title: "打开主窗口…", action: #selector(openSettings), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Quit
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = connected
            if !connected { self.currentBatteryLevel = nil }
            self.statusMenuItem.title = connected ? "状态：已连接 ✓" : "状态：未连接"
            self.statusItem.button?.appearsDisabled = !connected
            self.renderStatusItemButton()
            self.onConnectionChange?(connected)
        }
    }

    func setShowsBatteryPercentage(_ shows: Bool) {
        showsBatteryPercentage = shows
        UserDefaults.standard.set(shows, forKey: AppPreferenceKey.showBatteryInMenuBar)
        renderStatusItemButton()
    }

    func updateBatteryLevel(_ level: Int?) {
        DispatchQueue.main.async { [weak self] in
            self?.currentBatteryLevel = level
            self?.renderStatusItemButton()
        }
    }

    private func renderStatusItemButton() {
        guard let button = statusItem.button else { return }
        if showsBatteryPercentage {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.title = currentBatteryLevel.map { "  \($0)%" } ?? "  —"
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    /// Current connection state. Updated on the main thread by updateConnectionStatus.
    /// Read from any thread - it's a simple Bool, atomic on Apple platforms.
    private(set) var isConnected: Bool = false

    /// Current device product name (e.g. "Siri Remote"). Set by AppDelegate when
    /// the detector reports a device. Read by the popover to show the real name.
    var currentDeviceName: String?
    
    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
    }
    
    // Map HID codes to button names
    private let hidCodeToButton: [String: String] = [
        "0x000C:0x00CD": "playPause",    // Play/Pause
        "0x000C:0x00B5": "nextTrack",    // Next (not a physical button but for mapping)
        "0x000C:0x00B6": "prevTrack",    // Previous (not a physical button but for mapping)
        "0x000C:0x00E9": "volumeUp",     // Volume Up
        "0x000C:0x00EA": "volumeDown",   // Volume Down
        "0x0001:0x0086": "menu",         // Menu button (System Menu Main)
        "0x000C:0x0080": "select",       // Select button
        "0x000C:0x0040": "menu",         // Menu (alternate)
        "0x000C:0x0223": "menu",         // Home
        "0x000C:0x0224": "back",         // Back
    ]
    
    /// Get the action name for a given HID code (for event interception)
    func getMappingForHIDCode(_ hidCode: String) -> String? {
        guard let buttonName = hidCodeToButton[hidCode],
              let action = buttonMappings[buttonName] else {
            return nil
        }
        return action.rawValue
    }
    
    private func loadSwipeMappings() {
        if let saved = UserDefaults.standard.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (dirRaw, actionRaw) in saved {
                if let dir = SwipeDirection(rawValue: dirRaw),
                   let act = SwipeAction(rawValue: actionRaw) {
                    swipeMappings[dir] = act
                }
            }
        }
        // Fill any missing directions with defaults.
        for (dir, act) in Self.defaultSwipeMappings where swipeMappings[dir] == nil {
            swipeMappings[dir] = act
        }
    }

    private func saveSwipeMappings() {
        var toSave: [String: String] = [:]
        for (dir, act) in swipeMappings {
            toSave[dir.rawValue] = act.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "swipeMappings")
    }

    private func loadScrollSpeed() {
        if let raw = UserDefaults.standard.string(forKey: "scrollSpeed"),
           let speed = ScrollSpeed(rawValue: raw) {
            scrollSpeed = speed
        }
    }

    /// Update one profile's scroll speed. Only an active profile change is
    /// mirrored onto the runtime touch handler.
    func setScrollSpeed(profileId: String, speed: ScrollSpeed) {
        guard let i = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[i].scrollSpeed = speed.rawValue
        if profileId == currentProfileId, speed != scrollSpeed {
            scrollSpeed = speed
            UserDefaults.standard.set(speed.rawValue, forKey: "scrollSpeed")
            onScrollSpeedChange?(speed)
        }
        saveProfiles()
    }

    private func loadGyroSettings() {
        if UserDefaults.standard.object(forKey: "gyroGain") != nil {
            gyroGain = UserDefaults.standard.double(forKey: "gyroGain")
        }
        if UserDefaults.standard.object(forKey: "gyroSmoothing") != nil {
            gyroSmoothing = UserDefaults.standard.integer(forKey: "gyroSmoothing")
        }
        // Horizontal direction is now a fixed part of the A1962 axis mapping.
        UserDefaults.standard.removeObject(forKey: "gyroInvertHorizontal")
    }

    /// Update gyro feel from the settings window; persists + notifies the input handler.
    func setGyroSettings(gain: Double, smoothing: Int) {
        gyroGain = gain
        gyroSmoothing = smoothing
        UserDefaults.standard.set(gain, forKey: "gyroGain")
        UserDefaults.standard.set(smoothing, forKey: "gyroSmoothing")
        onGyroSettingsChange?()
    }

    private func loadTrackpadSensitivity() {
        if UserDefaults.standard.object(forKey: "trackpadSensitivity") != nil {
            trackpadSensitivity = UserDefaults.standard.integer(forKey: "trackpadSensitivity")
        }
    }

    /// Update trackpad cursor sensitivity from the settings window; persists + notifies.
    func setTrackpadSensitivity(_ value: Int) {
        trackpadSensitivity = value
        UserDefaults.standard.set(value, forKey: "trackpadSensitivity")
        onTrackpadSensitivityChange?(value)
    }

    /// Window-facing setter: update a button mapping, persist, and refresh the menu.
    func setMapping(for button: String, action: ButtonAction) {
        buttonMappings[button] = action
        saveMappings()
        rebuildMenu()
    }

    /// Window-facing setter: update a swipe mapping, persist, and refresh the menu.
    func setSwipeMapping(for direction: SwipeDirection, action: SwipeAction) {
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
    }

    /// Window-facing reset: restore all button + swipe mappings to defaults.
    func resetMappings() {
        buttonMappings = Self.defaultButtonMappings
        swipeMappings = Self.defaultSwipeMappings
        saveMappings()
        saveSwipeMappings()
        rebuildMenu()
    }

    // MARK: - Custom action payloads (user-defined text / key combo per mapping row)

    private func loadCustomPayloads() {
        let defaults = UserDefaults.standard
        customButtonTexts = defaults.dictionary(forKey: "profileCustomButtonTexts") as? [String: String] ?? [:]
        customSwipeTexts = defaults.dictionary(forKey: "profileCustomSwipeTexts") as? [String: String] ?? [:]
        customButtonKeys = defaults.dictionary(forKey: "profileCustomButtonKeyCombos") as? [String: [String: Any]] ?? [:]
        customSwipeKeys = defaults.dictionary(forKey: "profileCustomSwipeKeyCombos") as? [String: [String: Any]] ?? [:]

        // Before schema 2 custom payloads were global and keyed only by the
        // physical button/direction. Copy them into every existing profile so
        // upgrading preserves behaviour, then all future edits stay isolated.
        if defaults.integer(forKey: "customPayloadSchema") < 2 {
            let oldButtonTexts = defaults.dictionary(forKey: "customButtonTexts") as? [String: String] ?? [:]
            let oldSwipeTexts = defaults.dictionary(forKey: "customSwipeTexts") as? [String: String] ?? [:]
            let oldButtonKeys = defaults.dictionary(forKey: "customButtonKeyCombos") as? [String: [String: Any]] ?? [:]
            let oldSwipeKeys = defaults.dictionary(forKey: "customSwipeKeyCombos") as? [String: [String: Any]] ?? [:]
            for profile in profiles {
                for (key, value) in oldButtonTexts {
                    customButtonTexts[payloadKey(profileId: profile.id, itemKey: key)] = value
                }
                for (key, value) in oldSwipeTexts {
                    customSwipeTexts[payloadKey(profileId: profile.id, itemKey: key)] = value
                }
                for (key, value) in oldButtonKeys {
                    customButtonKeys[payloadKey(profileId: profile.id, itemKey: key)] = value
                }
                for (key, value) in oldSwipeKeys {
                    customSwipeKeys[payloadKey(profileId: profile.id, itemKey: key)] = value
                }
            }
            defaults.set(2, forKey: "customPayloadSchema")
            saveCustomPayloads()
        }
        remoteMicrophoneHoldKey = UserDefaults.standard.dictionary(
            forKey: "remoteMicrophoneHoldKeyCombo"
        )
    }

    private func payloadKey(profileId: String, itemKey: String) -> String {
        profileId + Self.customPayloadSeparator + itemKey
    }

    private func saveCustomPayloads() {
        let defaults = UserDefaults.standard
        defaults.set(customButtonTexts, forKey: "profileCustomButtonTexts")
        defaults.set(customSwipeTexts, forKey: "profileCustomSwipeTexts")
        defaults.set(customButtonKeys, forKey: "profileCustomButtonKeyCombos")
        defaults.set(customSwipeKeys, forKey: "profileCustomSwipeKeyCombos")
    }

    func customText(forButton button: String, profileId: String? = nil) -> String? {
        customButtonTexts[payloadKey(profileId: profileId ?? currentProfileId, itemKey: button)]
    }
    func customKeyCombo(forButton button: String, profileId: String? = nil) -> [String: Any]? {
        customButtonKeys[payloadKey(profileId: profileId ?? currentProfileId, itemKey: button)]
    }
    func customText(forSwipe direction: SwipeDirection, profileId: String? = nil) -> String? {
        customSwipeTexts[payloadKey(profileId: profileId ?? currentProfileId, itemKey: direction.rawValue)]
    }
    func customKeyCombo(forSwipe direction: SwipeDirection, profileId: String? = nil) -> [String: Any]? {
        customSwipeKeys[payloadKey(profileId: profileId ?? currentProfileId, itemKey: direction.rawValue)]
    }
    func remoteMicrophoneHoldKeyCombo() -> [String: Any]? { remoteMicrophoneHoldKey }

    /// System-volume key represented by the active mapping, including a key
    /// captured through the custom-key recorder.
    func mappedSystemVolumeKeyCode(forButton button: String) -> Int? {
        switch getMapping(for: button) {
        case .systemVolumeUp:
            return Int(NX_KEYTYPE_SOUND_UP)
        case .systemVolumeDown:
            return Int(NX_KEYTYPE_SOUND_DOWN)
        case .customKey:
            return customKeyCombo(forButton: button)?["systemKeyCode"] as? Int
        default:
            return nil
        }
    }

    /// True only when the mapped system-volume direction matches the physical
    /// button. In that case the remote's native AVRCP change is the single
    /// source of truth and no synthetic key should be posted.
    func usesPhysicalVolumePassThrough(forButton button: String) -> Bool {
        let physicalCode: Int
        switch button {
        case "volumeUp": physicalCode = Int(NX_KEYTYPE_SOUND_UP)
        case "volumeDown": physicalCode = Int(NX_KEYTYPE_SOUND_DOWN)
        default: return false
        }
        return mappedSystemVolumeKeyCode(forButton: button) == physicalCode
    }

    /// Window-facing setters. Empty text / nil combo removes the entry.
    func setCustomText(forButton button: String, text: String, profileId: String? = nil) {
        let key = payloadKey(profileId: profileId ?? currentProfileId, itemKey: button)
        customButtonTexts[key] = text.isEmpty ? nil : text
        saveCustomPayloads()
    }

    func setCustomText(forSwipe direction: SwipeDirection, text: String, profileId: String? = nil) {
        let key = payloadKey(profileId: profileId ?? currentProfileId, itemKey: direction.rawValue)
        customSwipeTexts[key] = text.isEmpty ? nil : text
        saveCustomPayloads()
    }

    func setCustomKeyCombo(forButton button: String, combo: [String: Any], profileId: String? = nil) {
        let key = payloadKey(profileId: profileId ?? currentProfileId, itemKey: button)
        let isEmpty = (combo["keyCode"] as? Int ?? 0) == 0 && (combo["label"] as? String ?? "").isEmpty
        customButtonKeys[key] = isEmpty ? nil : combo
        saveCustomPayloads()
    }

    func setCustomKeyCombo(forSwipe direction: SwipeDirection, combo: [String: Any], profileId: String? = nil) {
        let key = payloadKey(profileId: profileId ?? currentProfileId, itemKey: direction.rawValue)
        let isEmpty = (combo["keyCode"] as? Int ?? 0) == 0 && (combo["label"] as? String ?? "").isEmpty
        customSwipeKeys[key] = isEmpty ? nil : combo
        saveCustomPayloads()
    }

    func setRemoteMicrophoneHoldKeyCombo(_ combo: [String: Any]?) {
        remoteMicrophoneHoldKey = combo
        if let combo {
            UserDefaults.standard.set(combo, forKey: "remoteMicrophoneHoldKeyCombo")
        } else {
            UserDefaults.standard.removeObject(forKey: "remoteMicrophoneHoldKeyCombo")
        }
    }

    /// Execute a custom text action (types into the frontmost app, no Enter).
    func executeCustomText(_ text: String) {
        typeString(text)
    }

    /// Execute a custom key-combo action (modifiers + virtual keyCode).
    func executeCustomKey(keyCode: Int, modifiers: [String], systemKeyCode: Int? = nil,
                          sourceButton: String? = nil) {
        if let systemKeyCode {
            if let sourceButton,
               sourceButton == "volumeUp" || sourceButton == "volumeDown" {
                if usesPhysicalVolumePassThrough(forButton: sourceButton) {
                    // The matching AVRCP event already performs this action.
                    return
                }
                rmDebug("🔊 deferring opposite mapped volume key for \(sourceButton)")
                VolumeRevertGuard.shared.performAfterGuard { [weak self] in
                    self?.mediaController?.sendSystemKey(nxKeyCode: Int32(systemKeyCode))
                }
                return
            }
            mediaController?.sendSystemKey(nxKeyCode: Int32(systemKeyCode))
        } else if keyCode == kVK_Function || modifiers.contains("fn") {
            sendFnKeyTap()
        } else {
            sendKey(keyCode, flags: Self.flags(fromModifierNames: modifiers))
        }
    }

    private func sendFnKeyTap() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(source: source) {
            down.type = .flagsChanged
            down.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
            down.flags = .maskSecondaryFn
            down.post(tap: .cghidEventTap)
        }
        usleep(10000)
        if let up = CGEvent(source: source) {
            up.type = .flagsChanged
            up.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Function))
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }

    static func flags(fromModifierNames modifiers: [String]) -> CGEventFlags {
        var f = CGEventFlags()
        for m in modifiers {
            switch m {
            case "cmd":   f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "opt":   f.insert(.maskAlternate)
            case "ctrl":  f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    func getSwipeMapping(for direction: SwipeDirection) -> SwipeAction {
        return swipeMappings[direction] ?? .none
    }

    /// Execute the action bound to a swipe direction. Slash-command actions type text
    /// (no Enter — user presses Enter themselves). Arrow/modifier actions send key events.
    func executeSwipe(_ direction: SwipeDirection) {
        let action = swipeMappings[direction] ?? SwipeAction.none
        switch action {
        case .none:
            break
        case .upArrow:
            sendKey(kVK_UpArrow)
        case .downArrow:
            sendKey(kVK_DownArrow)
        case .leftArrow:
            sendKey(kVK_LeftArrow)
        case .rightArrow:
            sendKey(kVK_RightArrow)
        case .modeSwitch:
            sendKey(kVK_Tab, flags: .maskShift)
        case .bKey:
            sendKey(kVK_ANSI_B)
        case .wKey:
            sendKey(kVK_ANSI_W)
        case .mediaPlayPause:
            mediaController?.sendMediaKey(.playPause)
        case .mediaNext:
            mediaController?.sendMediaKey(.next)
        case .mediaPrev:
            mediaController?.sendMediaKey(.previous)
        case .mediaMute:
            mediaController?.sendMediaKey(.mute)
        case .btw, .schedule, .ultrathink:
            // Trailing space: user typically continues with an argument or prose.
            typeString(action.rawValue + " ")
        case .compact, .config, .context, .effort, .`init`,
             .model, .remoteControl, .tasks, .usage:
            // No trailing space: these commands stand alone or open an interactive picker.
            typeString(action.rawValue)
        case .customText:
            if let text = customText(forSwipe: direction) { typeString(text) }
        case .customKey:
            if let combo = customKeyCombo(forSwipe: direction),
               let keyCode = combo["keyCode"] as? Int,
               let modifiers = combo["modifiers"] as? [String] {
                executeCustomKey(keyCode: keyCode, modifiers: modifiers,
                                 systemKeyCode: combo["systemKeyCode"] as? Int)
            }
        }
    }

    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
    private func typeString(_ s: String) {
        let utf16 = Array(s.utf16)
        let count = utf16.count
        guard count > 0 else { return }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            down?.post(tap: .cghidEventTap)
            usleep(5000)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Execute an action by name. `button` identifies the source button so
    /// custom actions can look up their per-button payload (text / key combo).
    func executeAction(_ actionName: String, button: String) {
        guard let action = ButtonAction(rawValue: actionName) else { return }

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
        case .spaceKey:
            sendKey(kVK_Space)
        case .rightCmd:
            sendModifierTap(kVK_RightCommand, flag: .maskCommand)
        case .rightOpt:
            sendModifierTap(kVK_RightOption, flag: .maskAlternate)
        case .remoteMicrophone:
            break
        case .mediaPlayPause:
            mediaController?.sendMediaKey(.playPause)
        case .mediaNext:
            mediaController?.sendMediaKey(.next)
        case .mediaPrev:
            mediaController?.sendMediaKey(.previous)
        case .mediaMute:
            mediaController?.sendMediaKey(.mute)
        case .systemVolumeUp, .systemVolumeDown:
            let keyCode = action == .systemVolumeUp
                ? Int(NX_KEYTYPE_SOUND_UP) : Int(NX_KEYTYPE_SOUND_DOWN)
            if !usesPhysicalVolumePassThrough(forButton: button) {
                VolumeRevertGuard.shared.performAfterGuard { [weak self] in
                    self?.mediaController?.sendSystemKey(nxKeyCode: Int32(keyCode))
                }
            }
        case .presentation:
            sendKey(kVK_ANSI_P, flags: [.maskCommand, .maskAlternate])
        case .trackpadClick:
            performClick()
        case .customText:
            if let text = customText(forButton: button) { typeString(text) }
        case .customKey:
            if let combo = customKeyCombo(forButton: button),
               let keyCode = combo["keyCode"] as? Int,
               let modifiers = combo["modifiers"] as? [String] {
                executeCustomKey(keyCode: keyCode, modifiers: modifiers,
                                 systemKeyCode: combo["systemKeyCode"] as? Int,
                                 sourceButton: button)
            }
        }
    }

    private func performClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    /// Tap a modifier key alone (e.g. Right Command) — used to trigger push-to-talk dictation.
    private func sendModifierTap(_ keyCode: Int, flag: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flag
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }
    
    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }

    // MARK: - Profiles + app presets

    /// Canonical defaults for built-in profiles. Used by loadProfiles() seeding and
    /// resetProfileToDefault() to restore a profile to its factory mappings.
    private static let builtinSeeds: [(id: String, name: String, buttonMappings: [String: ButtonAction], swipeMappings: [SwipeDirection: SwipeAction], trackpadMode: String)] = [
        ("default", "默认配置", defaultButtonMappings, defaultSwipeMappings, "mouse"),
        ("coding",  "Vibe Coding", codingButtonMappings, codingSwipeMappings, "gesture"),
        ("demo",    "演示模式", demoButtonMappings,    demoSwipeMappings,    "gesture"),
        ("media",   "媒体播放", mediaButtonMappings,   mediaSwipeMappings,   "gesture"),
    ]

    private func loadProfiles() {
        let builtinSeeds = Self.builtinSeeds

        var loaded: [Profile] = []
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            loaded = saved
        }

        // Profile schema version: bump when built-in profile definitions change so
        // existing users' built-in profiles get refreshed to the new canonical mappings.
        // User-created (non-builtin) profiles are never touched.
        let profileSchema = 12
        let savedSchema = UserDefaults.standard.integer(forKey: "profileSchema")
        if savedSchema < 11 {
            // Overwrite built-in profiles with canonical defaults.
            for seed in builtinSeeds {
                if let idx = loaded.firstIndex(where: { $0.id == seed.id && $0.builtin }) {
                    loaded[idx].buttonMappings = seed.buttonMappings
                    loaded[idx].swipeMappings = swipeDirectionKeys(seed.swipeMappings)
                    loaded[idx].name = seed.name
                    loaded[idx].trackpadMode = seed.trackpadMode
                }
            }
        }
        if savedSchema < 12 {
            // The virtual-microphone default landed after schema 11 had
            // already shipped. Migrate only the former factory Siri action so
            // user edits to every other built-in mapping remain untouched.
            for index in loaded.indices where loaded[index].builtin &&
                (loaded[index].id == "default" || loaded[index].id == "coding") &&
                loaded[index].buttonMappings["siri"] == .spaceKey {
                loaded[index].buttonMappings["siri"] = .remoteMicrophone
            }
        }
        if savedSchema < profileSchema {
            UserDefaults.standard.set(profileSchema, forKey: "profileSchema")
        }

        // Idempotently append any missing built-in. Existing users gain
        // "演示模式" / "媒体播放" without disturbing their saved profiles;
        // fresh installs get all three seeded from per-profile canonical defaults.
        for seed in builtinSeeds where !loaded.contains(where: { $0.id == seed.id }) {
            loaded.append(Profile(
                id: seed.id, name: seed.name, builtin: true,
                buttonMappings: seed.buttonMappings,
                swipeMappings: swipeDirectionKeys(seed.swipeMappings),
                trackpadMode: seed.trackpadMode
            ))
        }

        profiles = loaded
        currentProfileId = UserDefaults.standard.string(forKey: "currentProfileId") ?? "default"
        applyProfileMappings(profileId: currentProfileId)
        saveProfiles()
    }

    private func loadAppPresets() {
        if let data = UserDefaults.standard.data(forKey: "appPresets"),
           let saved = try? JSONDecoder().decode([AppPreset].self, from: data) {
            appPresets = saved
        }
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: "profiles")
        UserDefaults.standard.set(currentProfileId, forKey: "currentProfileId")
    }

    private func saveAppPresets() {
        guard let data = try? JSONEncoder().encode(appPresets) else { return }
        UserDefaults.standard.set(data, forKey: "appPresets")
    }

    /// Convert enum-keyed swipe mappings to String-keyed form (rawValues) for
    /// Profile storage, which keeps the JSON shape stable and easy to diff.
    private func swipeDirectionKeys(_ m: [SwipeDirection: SwipeAction]) -> [String: SwipeAction] {
        var out: [String: SwipeAction] = [:]
        for (k, v) in m { out[k.rawValue] = v }
        return out
    }
    private func swipeDirectionMap(_ m: [String: SwipeAction]) -> [SwipeDirection: SwipeAction] {
        var out: [SwipeDirection: SwipeAction] = [:]
        for (k, v) in m {
            if let d = SwipeDirection(rawValue: k) { out[d] = v }
        }
        return out
    }

    /// Overlay a profile's mappings onto the runtime buttonMappings/swipeMappings,
    /// so the existing menu + RemoteInputHandler paths keep working unchanged.
    private func applyProfileMappings(profileId: String) {
        guard let p = profiles.first(where: { $0.id == profileId }) else { return }
        buttonMappings = p.buttonMappings
        swipeMappings = swipeDirectionMap(p.swipeMappings)
        let profileScrollSpeed = ScrollSpeed(rawValue: p.scrollSpeed) ?? .medium
        if scrollSpeed != profileScrollSpeed {
            scrollSpeed = profileScrollSpeed
            UserDefaults.standard.set(profileScrollSpeed.rawValue, forKey: "scrollSpeed")
            onScrollSpeedChange?(profileScrollSpeed)
        }
        onTrackpadModeChange?(p.trackpadMode)
        rebuildMenu()
    }

    /// The currently-active profile. Falls back to the first profile if the
    /// stored id went stale (e.g. profile deleted via UI).
    var currentProfile: Profile {
        profiles.first(where: { $0.id == currentProfileId }) ?? profiles.first ?? Profile(
            id: "default", name: "默认配置", builtin: true,
            buttonMappings: Self.defaultButtonMappings, swipeMappings: swipeDirectionKeys(Self.defaultSwipeMappings))
    }

    @discardableResult
    func createProfile(name: String) -> String {
        let base = currentProfile
        let id = "custom-\(Int(Date().timeIntervalSince1970 * 1000))"
        profiles.append(Profile(id: id, name: name, builtin: false,
                                buttonMappings: base.buttonMappings,
                                swipeMappings: base.swipeMappings,
                                trackpadMode: base.trackpadMode,
                                scrollSpeed: base.scrollSpeed))
        copyCustomPayloads(from: base.id, to: id)
        saveProfiles()
        return id
    }

    func deleteProfile(id: String) {
        guard let p = profiles.first(where: { $0.id == id }), !p.builtin else { return }
        profiles.removeAll { $0.id == id }
        removeCustomPayloads(profileId: id)
        if currentProfileId == id {
            currentProfileId = "default"
            applyProfileMappings(profileId: "default")
            onCurrentProfileChange?(currentProfileId)
        }
        for i in appPresets.indices where appPresets[i].profileId == id {
            appPresets[i].profileId = "default"
        }
        saveProfiles()
        saveAppPresets()
    }

    func renameProfile(id: String, name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
        saveProfiles()
    }

    /// Set the trackpad mode ("mouse" or "gesture") for a specific profile.
    func setTrackpadMode(profileId: String, mode: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[i].trackpadMode = mode
        if profileId == currentProfileId {
            onTrackpadModeChange?(mode)
        }
        saveProfiles()
    }

    /// Switch the active profile. Copies its mappings onto the runtime state,
    /// fires change callback so the settings window + menu can refresh.
    func selectProfile(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard id != currentProfileId else { return }
        currentProfileId = id
        applyProfileMappings(profileId: id)
        saveProfiles()
        onCurrentProfileChange?(currentProfileId)
    }

    /// Persist a mapping change into a specific profile. When that profile is
    /// currently active, also update the runtime mappings so the existing
    /// pushMappings path stays in sync.
    func setProfileMapping(profileId: String, target: String, key: String, actionRaw: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        var p = profiles[i]
        switch target {
        case "button":
            if let action = ButtonAction(rawValue: actionRaw) {
                p.buttonMappings[key] = action
            }
        case "swipe":
            if let action = SwipeAction(rawValue: actionRaw) {
                p.swipeMappings[key] = action
            }
        default: return
        }
        profiles[i] = p
        if profileId == currentProfileId {
            switch target {
            case "button":
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[key] = action
                    rebuildMenu()
                }
            case "swipe":
                if let action = SwipeAction(rawValue: actionRaw),
                   let dir = SwipeDirection(rawValue: key) {
                    swipeMappings[dir] = action
                    rebuildMenu()
                }
            default: break
            }
        }
        saveProfiles()
    }

    /// Reset a specific profile to its canonical default mappings. For built-in profiles
    /// this restores the factory bindings; for user-created profiles it clears to .none.
    func resetProfileToDefault(profileId: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        if let seed = Self.builtinSeeds.first(where: { $0.id == profileId }) {
            profiles[i].buttonMappings = seed.buttonMappings
            profiles[i].swipeMappings = swipeDirectionKeys(seed.swipeMappings)
            profiles[i].scrollSpeed = ScrollSpeed.medium.rawValue
        } else {
            // User-created profile: clear all to .none
            profiles[i].buttonMappings = profiles[i].buttonMappings.mapValues { _ in .none }
            profiles[i].swipeMappings = profiles[i].swipeMappings.mapValues { _ in .none }
            profiles[i].scrollSpeed = ScrollSpeed.medium.rawValue
        }
        removeCustomPayloads(profileId: profileId)
        if profileId == currentProfileId {
            applyProfileMappings(profileId: profileId)
            rebuildMenu()
        }
        saveProfiles()
    }

    private func copyCustomPayloads(from sourceProfileId: String, to destinationProfileId: String) {
        let sourcePrefix = sourceProfileId + Self.customPayloadSeparator
        func copiedKey(_ key: String) -> String {
            destinationProfileId + Self.customPayloadSeparator + String(key.dropFirst(sourcePrefix.count))
        }
        for (key, value) in Array(customButtonTexts) where key.hasPrefix(sourcePrefix) {
            customButtonTexts[copiedKey(key)] = value
        }
        for (key, value) in Array(customSwipeTexts) where key.hasPrefix(sourcePrefix) {
            customSwipeTexts[copiedKey(key)] = value
        }
        for (key, value) in Array(customButtonKeys) where key.hasPrefix(sourcePrefix) {
            customButtonKeys[copiedKey(key)] = value
        }
        for (key, value) in Array(customSwipeKeys) where key.hasPrefix(sourcePrefix) {
            customSwipeKeys[copiedKey(key)] = value
        }
        saveCustomPayloads()
    }

    private func removeCustomPayloads(profileId: String) {
        let prefix = profileId + Self.customPayloadSeparator
        customButtonTexts = customButtonTexts.filter { !$0.key.hasPrefix(prefix) }
        customSwipeTexts = customSwipeTexts.filter { !$0.key.hasPrefix(prefix) }
        customButtonKeys = customButtonKeys.filter { !$0.key.hasPrefix(prefix) }
        customSwipeKeys = customSwipeKeys.filter { !$0.key.hasPrefix(prefix) }
        saveCustomPayloads()
    }

    func addAppPreset(bundleId: String, appName: String, profileId: String, iconData: Data?) {
        if let i = appPresets.firstIndex(where: { $0.bundleId == bundleId }) {
            appPresets[i].appName = appName
            appPresets[i].profileId = profileId
            appPresets[i].iconData = iconData ?? appPresets[i].iconData
        } else {
            appPresets.append(AppPreset(bundleId: bundleId, appName: appName,
                                        profileId: profileId, iconData: iconData))
        }
        saveAppPresets()
    }

    func removeAppPreset(bundleId: String) {
        appPresets.removeAll { $0.bundleId == bundleId }
        saveAppPresets()
    }

    func setAppPresetProfile(bundleId: String, profileId: String) {
        guard profiles.contains(where: { $0.id == profileId }),
              let i = appPresets.firstIndex(where: { $0.bundleId == bundleId }) else {
            rmDebug("⚠️ preset profile ignored: app=\(bundleId) profile=\(profileId)")
            return
        }
        appPresets[i].profileId = profileId
        saveAppPresets()
        rmDebug("🎛 preset profile updated: app=\(bundleId) profile=\(profileId)")
    }

    /// Called from the NSWorkspace observer when the frontmost app changes.
    /// Apply the bound profile, or restore the default profile for an unbound
    /// app. Always resets the system override so automatic switching resumes.
    func applyAppActivation(bundleId: String) {
        isSystemOverride = false
        let profileId = appPresets.first(where: { $0.bundleId == bundleId })?.profileId ?? "default"
        rmDebug("🎛 app activated: \(bundleId) -> profile=\(profileId)")
        selectProfile(id: profileId)
    }

    /// True when user manually forced the system (default) profile via TV key.
    private(set) var isSystemOverride = false
    private var hudWindow: NSWindow?
    private var hudTimer: Timer?

    /// Toggle between app-preset profile and system default profile (TV key).
    func toggleSystemOverride() {
        isSystemOverride.toggle()
        if isSystemOverride {
            selectProfile(id: "default")
        } else {
            // Restore the frontmost app's preset, or fall back to default.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let presetId = front.flatMap { bid in appPresets.first { $0.bundleId == bid }?.profileId }
            selectProfile(id: presetId ?? "default")
        }
        // HUD shows the actual profile name now active.
        let name = profiles.first { $0.id == currentProfileId }?.name ?? currentProfileId
        showHUD(name)
    }

    /// Brief floating HUD at the bottom-center of the screen (like macOS volume indicator).
    private func showHUD(_ text: String) {
        hudTimer?.invalidate()

        // Reuse or create the borderless overlay window.
        if hudWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.ignoresMouseEvents = true
            w.hasShadow = false

            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            w.contentView?.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor),
            ])
            hudWindow = w
        }

        guard let win = hudWindow,
              let label = win.contentView?.subviews.first as? NSTextField,
              let screen = NSScreen.main else { return }

        label.stringValue = text

        // Rounded-rect dark background via layer.
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        win.contentView?.layer?.cornerRadius = 10

        // Position: bottom-center of the main screen, ~80px from the bottom edge.
        let screenFrame = screen.visibleFrame
        let winSize = NSSize(width: 200, height: 44)
        let x = screenFrame.midX - winSize.width / 2
        let y = screenFrame.origin.y + 80
        win.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: winSize), display: true)

        win.alphaValue = 1
        win.orderFrontRegardless()

        // Fade out after 1.5s.
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.hudWindow?.animator().alphaValue = 0
            }, completionHandler: {
                self?.hudWindow?.orderOut(nil)
            })
        }
    }
}

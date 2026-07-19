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
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case trackpadClick = "Mouse Click"
    case customText = "Custom Text"
    case customKey = "Custom Key"
    case none = "None"

    /// Push-to-talk dictation needs the virtual key held for the full press duration.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// only offered for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt: return true
        default: return false
        }
    }

    /// Menu display name. rawValue stays English: it's the UserDefaults persistence
    /// key and round-trips through executeAction(_:), so it must remain stable.
    var displayName: String {
        switch self {
        case .enterKey:      return "回车：提交提示词"
        case .upKey:         return "上箭头：向上导航"
        case .downKey:       return "下箭头：向下导航"
        case .escKey:        return "Esc：返回"
        case .ctrlC:         return "Control + C：取消输入"
        case .spaceKey:      return "空格：Claude 语音听写"
        case .rightCmd:      return "右 Command：第三方语音听写"
        case .rightOpt:      return "右 Option：第三方语音听写"
        case .trackpadClick: return "鼠标点击"
        case .customText:    return "自定义文本"
        case .customKey:     return "自定义按键"
        case .none:          return "无"
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
    // Priority order: direction-matched arrow (filtered per submenu), then Mode Switching,
    // then ultrathink, then slash commands alphabetically, None last.
    case leftArrow     = "Left: Navigate Left"
    case rightArrow    = "Right: Navigate Right"
    case modeSwitch    = "Mode Switching (Shift + Tab)"
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
        case .leftArrow:  return "左箭头：向左导航"
        case .rightArrow: return "右箭头：向右导航"
        case .modeSwitch: return "模式切换 (Shift + Tab)"
        case .customText: return "自定义文本"
        case .customKey:  return "自定义按键"
        case .none:       return "无"
        default:          return rawValue
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
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: ButtonAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: SwipeAction] = [:]

    // Custom action payloads, keyed by button key / swipe direction rawValue.
    // Key combo dict: {"keyCode": Int, "modifiers": ["cmd","shift","opt","ctrl"], "label": "⌘⇧P"}.
    private var customButtonTexts: [String: String] = [:]
    private var customButtonKeys: [String: [String: Any]] = [:]
    private var customSwipeTexts: [String: String] = [:]
    private var customSwipeKeys: [String: [String: Any]] = [:]

    private static let defaultSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .usage,
        .down:  .compact,
        .left:  .model,
        .right: .modeSwitch,
    ]

    private static let defaultButtonMappings: [String: ButtonAction] = [
        "playPause": .enterKey,
        "menu": .escKey,
        "select": .trackpadClick,
        "volumeUp": .upKey,
        "volumeDown": .downKey,
        "siri": .spaceKey,
        "tv": .ctrlC
    ]

    /// Mappable buttons in display order, shared by the menu bar and the settings
    /// window. gesture is a cosmetic label for the window's 手势 column.
    static let buttonRows: [(key: String, label: String, gesture: String)] = [
        ("select",     "触控板按下",  "单击"),
        ("menu",       "Menu 键",    "单击"),
        ("tv",         "TV 键",      "单击"),
        ("siri",       "Siri 键",    "按住"),
        ("playPause",  "播放/暂停键", "单击"),
        ("volumeUp",   "音量加",     "单击"),
        ("volumeDown", "音量减",     "单击"),
    ]

    /// Actions offered for a button: hold-to-talk actions only on buttons that
    /// emit release events; Mouse Click only on the trackpad click.
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
    /// lower cutoff → heavier smoothing. 67 ≈ 0.79, matching the original 0.8.
    var gyroMinCutoff: Double { 2.0 - Double(gyroSmoothing) / 100.0 * 1.8 }

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
        loadCustomPayloads()
        loadProfiles()
        loadAppPresets()
        setupMenuBar()
    }
    
    private func loadMappings() {
        let defaultMappings = Self.defaultButtonMappings

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        let currentSchema = 4
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
    
    /// Procedurally draw the menu-bar icon — a walkie-talkie glyph mirroring the
    /// Figma reference (36-unit viewBox: antenna + body with display + speaker
    /// holes via even-odd fill). 2× centered scale matches the menu-bar reading
    /// size; overflow clips at the canvas edges by design.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = pt / 24.0  // 0.75

            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(1.7 * scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Body: rounded rect (8.5, 2.5, 7, 19, rx 3) - stroke only, matches SVG fill="none".
            let bodyRect = CGRect(x: 8.5 * scale, y: 2.5 * scale,
                                  width: 7 * scale, height: 19 * scale)
            ctx.addPath(CGPath(roundedRect: bodyRect,
                               cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil))
            ctx.strokePath()

            // Circle near top (touchpad / Siri button): cx=12, cy=7.4, r=2.4
            let circleRect = CGRect(x: (12 - 2.4) * scale, y: (7.4 - 2.4) * scale,
                                    width: 4.8 * scale, height: 4.8 * scale)
            ctx.addEllipse(in: circleRect)
            ctx.strokePath()

            // Two horizontal lines (buttons): 10.4,13.6 -> 13.6,13.6 and 10.4,16.4 -> 13.6,16.4
            ctx.move(to: CGPoint(x: 10.4 * scale, y: 13.6 * scale))
            ctx.addLine(to: CGPoint(x: 13.6 * scale, y: 13.6 * scale))
            ctx.strokePath()

            ctx.move(to: CGPoint(x: 10.4 * scale, y: 16.4 * scale))
            ctx.addLine(to: CGPoint(x: 13.6 * scale, y: 16.4 * scale))
            ctx.strokePath()

            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.makeWaveIcon()
        button.title = ""

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
        
        // Button Mappings submenu
        let mappingsItem = NSMenuItem(title: "按钮映射", action: nil, keyEquivalent: "")
        let mappingsSubmenu = NSMenu()

        for (key, label, _) in Self.buttonRows {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()

            for action in Self.availableActions(forButton: key) {
                let actionItem = NSMenuItem(title: action.displayName, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (key, action)

                if buttonMappings[key] == action {
                    actionItem.state = .on
                }

                actionSubmenu.addItem(actionItem)
            }

            buttonItem.submenu = actionSubmenu
            mappingsSubmenu.addItem(buttonItem)
        }
        
        mappingsItem.submenu = mappingsSubmenu
        menu.addItem(mappingsItem)

        // Swipe Gestures submenu
        let swipeItem = NSMenuItem(title: "滑动手势", action: nil, keyEquivalent: "")
        let swipeSubmenu = NSMenu()
        let swipes: [(SwipeDirection, String)] = [
            (.up,    "上滑"),
            (.down,  "下滑"),
            (.left,  "左滑"),
            (.right, "右滑"),
        ]
        for (direction, label) in swipes {
            let dirItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionsMenu = NSMenu()
            for action in Self.availableSwipeActions(for: direction) {
                let actionItem = NSMenuItem(title: action.displayName, action: #selector(changeSwipeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (direction, action)
                if swipeMappings[direction] == action {
                    actionItem.state = .on
                }
                actionsMenu.addItem(actionItem)
            }
            dirItem.submenu = actionsMenu
            swipeSubmenu.addItem(dirItem)
        }
        swipeItem.submenu = swipeSubmenu
        menu.addItem(swipeItem)

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
    
    @objc private func changeMapping(_ sender: NSMenuItem) {
        guard let (buttonKey, action) = sender.representedObject as? (String, ButtonAction) else {
            return
        }
        buttonMappings[buttonKey] = action
        saveMappings()
        rebuildMenu()
    }

    @objc private func changeSwipeMapping(_ sender: NSMenuItem) {
        guard let (direction, action) = sender.representedObject as? (SwipeDirection, SwipeAction) else {
            return
        }
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = connected
            self.statusMenuItem.title = connected ? "状态：已连接 ✓" : "状态：未连接"
            self.statusItem.button?.appearsDisabled = !connected
            self.onConnectionChange?(connected)
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

    /// Update scroll speed from the settings window; persists + notifies the touch handler.
    func setScrollSpeed(_ speed: ScrollSpeed) {
        guard speed != scrollSpeed else { return }
        scrollSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "scrollSpeed")
        onScrollSpeedChange?(speed)
    }

    private func loadGyroSettings() {
        if UserDefaults.standard.object(forKey: "gyroGain") != nil {
            gyroGain = UserDefaults.standard.double(forKey: "gyroGain")
        }
        if UserDefaults.standard.object(forKey: "gyroSmoothing") != nil {
            gyroSmoothing = UserDefaults.standard.integer(forKey: "gyroSmoothing")
        }
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
        customButtonTexts = UserDefaults.standard.dictionary(forKey: "customButtonTexts") as? [String: String] ?? [:]
        customSwipeTexts = UserDefaults.standard.dictionary(forKey: "customSwipeTexts") as? [String: String] ?? [:]
        customButtonKeys = UserDefaults.standard.dictionary(forKey: "customButtonKeyCombos") as? [String: [String: Any]] ?? [:]
        customSwipeKeys = UserDefaults.standard.dictionary(forKey: "customSwipeKeyCombos") as? [String: [String: Any]] ?? [:]
    }

    func customText(forButton button: String) -> String? { customButtonTexts[button] }
    func customKeyCombo(forButton button: String) -> [String: Any]? { customButtonKeys[button] }
    func customText(forSwipe direction: SwipeDirection) -> String? { customSwipeTexts[direction.rawValue] }
    func customKeyCombo(forSwipe direction: SwipeDirection) -> [String: Any]? { customSwipeKeys[direction.rawValue] }

    /// Window-facing setters. Empty text / nil combo removes the entry.
    func setCustomText(forButton button: String, text: String) {
        customButtonTexts[button] = text.isEmpty ? nil : text
        UserDefaults.standard.set(customButtonTexts, forKey: "customButtonTexts")
    }

    func setCustomText(forSwipe direction: SwipeDirection, text: String) {
        customSwipeTexts[direction.rawValue] = text.isEmpty ? nil : text
        UserDefaults.standard.set(customSwipeTexts, forKey: "customSwipeTexts")
    }

    func setCustomKeyCombo(forButton button: String, combo: [String: Any]) {
        customButtonKeys[button] = combo
        UserDefaults.standard.set(customButtonKeys, forKey: "customButtonKeyCombos")
    }

    func setCustomKeyCombo(forSwipe direction: SwipeDirection, combo: [String: Any]) {
        customSwipeKeys[direction.rawValue] = combo
        UserDefaults.standard.set(customSwipeKeys, forKey: "customSwipeKeyCombos")
    }

    /// Execute a custom text action (types into the frontmost app, no Enter).
    func executeCustomText(_ text: String) {
        typeString(text)
    }

    /// Execute a custom key-combo action (modifiers + virtual keyCode).
    func executeCustomKey(keyCode: Int, modifiers: [String]) {
        sendKey(keyCode, flags: Self.flags(fromModifierNames: modifiers))
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
        case .leftArrow:
            sendKey(kVK_LeftArrow)
        case .rightArrow:
            sendKey(kVK_RightArrow)
        case .modeSwitch:
            sendKey(kVK_Tab, flags: .maskShift)
        case .btw, .schedule, .ultrathink:
            // Trailing space: user typically continues with an argument or prose.
            typeString(action.rawValue + " ")
        case .compact, .config, .context, .effort, .`init`,
             .model, .remoteControl, .tasks, .usage:
            // No trailing space: these commands stand alone or open an interactive picker.
            typeString(action.rawValue)
        case .customText:
            if let text = customSwipeTexts[direction.rawValue] { typeString(text) }
        case .customKey:
            if let combo = customSwipeKeys[direction.rawValue],
               let keyCode = combo["keyCode"] as? Int,
               let modifiers = combo["modifiers"] as? [String] {
                sendKey(keyCode, flags: Self.flags(fromModifierNames: modifiers))
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
        case .trackpadClick:
            performClick()
        case .customText:
            if let text = customButtonTexts[button] { typeString(text) }
        case .customKey:
            if let combo = customButtonKeys[button],
               let keyCode = combo["keyCode"] as? Int,
               let modifiers = combo["modifiers"] as? [String] {
                sendKey(keyCode, flags: Self.flags(fromModifierNames: modifiers))
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

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let saved = try? JSONDecoder().decode([Profile].self, from: data),
           !saved.isEmpty {
            profiles = saved
            currentProfileId = UserDefaults.standard.string(forKey: "currentProfileId") ?? "default"
            applyProfileMappings(profileId: currentProfileId)
        } else {
            // First run: seed a "default" profile from the runtime mappings.
            profiles = [Profile(id: "default", name: "默认映射", builtin: true,
                                buttonMappings: buttonMappings,
                                swipeMappings: swipeDirectionKeys(swipeMappings))]
            currentProfileId = "default"
            saveProfiles()
        }
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
        rebuildMenu()
    }

    /// The currently-active profile. Falls back to the first profile if the
    /// stored id went stale (e.g. profile deleted via UI).
    var currentProfile: Profile {
        profiles.first(where: { $0.id == currentProfileId }) ?? profiles.first ?? Profile(
            id: "default", name: "默认映射", builtin: true,
            buttonMappings: buttonMappings, swipeMappings: swipeDirectionKeys(swipeMappings))
    }

    @discardableResult
    func createProfile(name: String) -> String {
        let base = currentProfile
        let id = "custom-\(Int(Date().timeIntervalSince1970 * 1000))"
        profiles.append(Profile(id: id, name: name, builtin: false,
                                buttonMappings: base.buttonMappings,
                                swipeMappings: base.swipeMappings))
        saveProfiles()
        return id
    }

    func deleteProfile(id: String) {
        guard let p = profiles.first(where: { $0.id == id }), !p.builtin else { return }
        profiles.removeAll { $0.id == id }
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
        guard let i = appPresets.firstIndex(where: { $0.bundleId == bundleId }) else { return }
        appPresets[i].profileId = profileId
        saveAppPresets()
    }

    /// Called from the NSWorkspace observer when the frontmost app changes.
    /// If a preset binds it to a profile, flip the active profile; otherwise
    /// leave the current selection alone.
    func applyAppActivation(bundleId: String) {
        guard let p = appPresets.first(where: { $0.bundleId == bundleId }) else { return }
        selectProfile(id: p.profileId)
    }
}

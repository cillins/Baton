//
//  SettingsWindowController.swift
//  Baton
//
//  Hosts the React-based settings UI in a WKWebView inside an NSWindow.
//  The React app (built to web/dist/) is bundled at Resources/web/.
//  Baton is LSUIElement (no Dock icon by default); this controller flips
//  activation policy to .regular while the window is open so the app gets
//  a Dock icon and window chrome, then restores .accessory on close.
//
//  Bridge protocol (window.webkit.messageHandlers.bat):
//    JS -> Swift:
//      { type: 'requestInitialState' }           -> Swift responds by pushing state
//    Swift -> JS:
//      window.batonNative.setState({ connected, deviceName, version })
//

import AppKit
import WebKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let webViewController: WebViewController
    /// Last hardware generation (gen1/gen2) observed via `pushGeneration`. Cached
    /// here so subsequent `pushConnectionState` calls (which don't know about
    /// generation) can still forward it through to the bridge.
    private var lastGeneration: Generation?

    init(menuBarManager: MenuBarManager, remoteDetector: RemoteDetector?) {
        webViewController = WebViewController(menuBarManager: menuBarManager, remoteDetector: remoteDetector)
        let window = NSWindow(contentViewController: webViewController)
        window.title = "Baton"
        // Fixed at the design size (1020×684) - no resizing.
        // .fullSizeContentView lets the WKWebView extend up under the transparent
        // title bar so React's own titlebar draws flush with the top edge. The
        // system traffic-light buttons stay visible and functional, floating over
        // the content.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1020, height: 684))
        window.minSize = NSSize(width: 1020, height: 684)
        window.maxSize = NSSize(width: 1020, height: 684)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window = window else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Hide native traffic lights — Swift draws our own at y=23 in the titlebar.
        DispatchQueue.main.async {
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    /// Called by AppDelegate when connection state changes so the React UI
    /// can refresh its device status row live.
    func pushConnectionState(connected: Bool, deviceName: String?) {
        webViewController.pushState(
            connected: connected,
            deviceName: deviceName,
            generation: lastGeneration
        )
    }

    /// Called by AppDelegate when the connected device's hardware generation
    /// resolves (or when the device disconnects → nil). Drives the React-side
    /// `dev.art` switch so the right remote artwork is rendered.
    func pushGeneration(_ generation: Generation?) {
        rmDebug("🛰 pushGeneration: \(generation?.wireTag ?? "nil")")
        lastGeneration = generation
        webViewController.pushState(
            connected: webViewController.lastConnected,
            deviceName: webViewController.lastDeviceName,
            generation: generation
        )
    }

    /// Called by AppDelegate when BLE Battery Service notifies a new level
    /// (or on disconnect → nil). Drives the React `dev.batt` field.
    func pushBattery(_ battery: Int?) {
        rmDebug("🔋 pushBattery: \(battery.map(String.init) ?? "nil")")
        webViewController.pushState(
            connected: webViewController.lastConnected,
            deviceName: webViewController.lastDeviceName,
            generation: lastGeneration,
            battery: battery
        )
    }

    /// Called by AppDelegate when the user picks a new appearance in the popover.
    /// Pushes the value into the React app so it updates its own state + localStorage.
    func pushAppearance(_ appearance: String) {
        // appearance is one of "auto"/"light"/"dark" - safe to inline-quote.
        let js = "window.batonNative && window.batonNative.setAppearance && window.batonNative.setAppearance(\"\(appearance)\");"
        webViewController.evaluateJS(js)
    }

    func windowWillClose(_ notification: Notification) {
        // Return to pure menu-bar (LSUIElement) form: no Dock icon, no window.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Web View Controller

private final class WebViewController: NSViewController, WKNavigationDelegate {
    private let webView: WKWebView
    private let bridge: WebBridge

    // Latest connection state, used as the source of truth when SettingsWindow
    // gets a partial update (e.g. only `generation` arrives after `connected`).
    private(set) var lastConnected: Bool = false
    private(set) var lastDeviceName: String?

    init(menuBarManager: MenuBarManager, remoteDetector: RemoteDetector?) {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        config.userContentController = userContent
        // Merge with system background so the React app blends with native chrome.
        config.applicationNameForUserAgent = "Baton/1.0"
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.bridge = WebBridge(menuBarManager: menuBarManager, remoteDetector: remoteDetector)
        super.init(nibName: nil, bundle: nil)
        bridge.webView = webView
        bridge.install(on: userContent)
        webView.navigationDelegate = self
        // Inject an error catcher at document start so we can see why React fails to mount.
        let errScript = WKUserScript(source: """
            window.__batonErrors = [];
            window.addEventListener('error', function(e){
              window.__batonErrors.push({msg: e.message, src: e.filename, line: e.lineno, col: e.colno, err: e.error && e.error.stack});
            });
            window.addEventListener('unhandledrejection', function(e){
              window.__batonErrors.push({promise: true, reason: e.reason && (e.reason.stack || e.reason.message || String(e.reason))});
            });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContent.addUserScript(errScript)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // Wrap WKWebView in a container that adds a drag overlay on top of the
        // titlebar area. WKWebView + fullSizeContentView hides the native
        // titlebar, so -webkit-app-region: drag isn't reliable — the Swift
        // overlay takes over by capturing mouseDown and calling performDrag.
        let container = WindowContainerView(buttonAreaRightInset: 200)
        self.view = container
        container.attachContent(webView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadIndex()
    }

    private func loadIndex() {
        // web/dist/index.html is bundled at Resources/web/index.html.
        let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
        guard let indexURL = indexURL else {
            print("⚠️ Settings UI: web/index.html not found in bundle")
            rmDebug("⚠️ Settings UI: web/index.html not found in bundle")
            // Fallback: show a basic error page so the window isn't blank.
            webView.loadHTMLString("<html><body style='font-family:-apple-system;color:#888;padding:24px'>设置界面资源未找到。请运行 cd web && npm install && npm run build 后重新打包。</body></html>", baseURL: nil)
            return
        }
        // allowingReadAccessToURL must cover ./assets/* so the JS/CSS load under file://
        let dir = indexURL.deletingLastPathComponent()
        print("🌐 Loading settings UI: \(indexURL.path)")
        rmDebug("🌐 Loading settings UI: \(indexURL.path)")
        let req = URLRequest(url: indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        webView.load(req)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        rmDebug("🌐 didStartProvisionalNavigation")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        rmDebug("🌐 didFinish: url=\(webView.url?.absoluteString ?? "?")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.bridge.pushState(connected: self.bridge.menuBarManager?.isConnected ?? false,
                                  deviceName: self.bridge.remoteDetector?.currentDeviceName,
                                  generation: self.bridge.remoteDetector?.currentGeneration)
            self.bridge.pushMappings()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        rmDebug("🌐 didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rmDebug("🌐 didFailProvisionalNavigation: \(error.localizedDescription)")
    }

    func pushState(connected: Bool, deviceName: String?, generation: Generation? = nil,
                   battery: Int? = nil) {
        lastConnected = connected
        lastDeviceName = deviceName
        bridge.pushState(connected: connected, deviceName: deviceName,
                         generation: generation, battery: battery)
    }

    func evaluateJS(_ js: String) {
        webView.evaluateJavaScript(js) { _, _ in /* ignore */ }
    }
}

// MARK: - Web Bridge (Swift <-> JS)

private final class WebBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var menuBarManager: MenuBarManager?
    weak var remoteDetector: RemoteDetector?

    init(menuBarManager: MenuBarManager, remoteDetector: RemoteDetector?) {
        self.menuBarManager = menuBarManager
        self.remoteDetector = remoteDetector
        super.init()
        // When the active profile changes (manual switch or app-activation
        // match), refresh the settings window so the per-row action labels and
        // active-profile badge stay in sync.
        menuBarManager.onCurrentProfileChange = { [weak self] _ in
            self?.pushMappings()
        }
    }

    func install(on userContent: WKUserContentController) {
        userContent.add(self, name: "bat")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "requestInitialState":
            pushState(connected: menuBarManager?.isConnected ?? false,
                      deviceName: remoteDetector?.currentDeviceName,
                      generation: remoteDetector?.currentGeneration)
            pushMappings()
        case "setButtonMapping":
            if let button = body["button"] as? String,
               let raw = body["action"] as? String,
               let action = ButtonAction(rawValue: raw) {
                menuBarManager?.setMapping(for: button, action: action)
                pushMappings()
            }
        case "setSwipeMapping":
            if let dirRaw = body["direction"] as? String,
               let direction = SwipeDirection(rawValue: dirRaw),
               let raw = body["action"] as? String,
               let action = SwipeAction(rawValue: raw) {
                menuBarManager?.setSwipeMapping(for: direction, action: action)
                pushMappings()
            }
        case "setScrollSpeed":
            if let raw = body["speed"] as? String,
               let speed = ScrollSpeed(rawValue: raw) {
                menuBarManager?.setScrollSpeed(speed)
                pushMappings()
            }
        case "setGyroSettings":
            if let gain = body["gain"] as? Double,
               let smoothing = body["smoothing"] as? Int {
                menuBarManager?.setGyroSettings(gain: gain, smoothing: smoothing)
                pushMappings()
            }
        case "setTrackpadSensitivity":
            if let value = body["sensitivity"] as? Int {
                menuBarManager?.setTrackpadSensitivity(value)
                pushMappings()
            }
        case "resetMappings":
            menuBarManager?.resetMappings()
            pushMappings()
        case "setCustomText":
            if let target = body["target"] as? String,
               let key = body["key"] as? String,
               let text = body["text"] as? String {
                if target == "button" {
                    menuBarManager?.setCustomText(forButton: key, text: text)
                } else if let dir = SwipeDirection(rawValue: key) {
                    menuBarManager?.setCustomText(forSwipe: dir, text: text)
                }
                pushMappings()
            }
        case "setCustomKey":
            if let target = body["target"] as? String,
               let key = body["key"] as? String,
               let keyCode = body["keyCode"] as? Int,
               let modifiers = body["modifiers"] as? [String] {
                let combo: [String: Any] = [
                    "keyCode": keyCode,
                    "modifiers": modifiers,
                    "label": body["label"] as? String ?? "",
                ]
                if target == "button" {
                    menuBarManager?.setCustomKeyCombo(forButton: key, combo: combo)
                } else if let dir = SwipeDirection(rawValue: key) {
                    menuBarManager?.setCustomKeyCombo(forSwipe: dir, combo: combo)
                }
                pushMappings()
            }
        case "setCurrentProfile":
            if let id = body["id"] as? String {
                menuBarManager?.selectProfile(id: id)
                pushMappings()
            }
        case "createProfile":
            if let name = body["name"] as? String, !name.isEmpty {
                _ = menuBarManager?.createProfile(name: name)
                pushMappings()
            }
        case "deleteProfile":
            if let id = body["id"] as? String {
                menuBarManager?.deleteProfile(id: id)
                pushMappings()
            }
        case "renameProfile":
            if let id = body["id"] as? String, let name = body["name"] as? String, !name.isEmpty {
                menuBarManager?.renameProfile(id: id, name: name)
                pushMappings()
            }
        case "setProfileMapping":
            if let pid = body["profileId"] as? String,
               let target = body["target"] as? String,
               let key = body["key"] as? String,
               let raw = body["action"] as? String {
                menuBarManager?.setProfileMapping(profileId: pid, target: target, key: key, actionRaw: raw)
                pushMappings()
            }
        case "addAppPreset":
            if let bid = body["bundleId"] as? String,
               let name = body["appName"] as? String,
               let pid = body["profileId"] as? String {
                let icon = (body["iconData"] as? String).flatMap { Data(base64Encoded: $0) }
                menuBarManager?.addAppPreset(bundleId: bid, appName: name, profileId: pid, iconData: icon)
                pushMappings()
            }
        case "removeAppPreset":
            if let bid = body["bundleId"] as? String {
                menuBarManager?.removeAppPreset(bundleId: bid)
                pushMappings()
            }
        case "setAppPresetProfile":
            if let bid = body["bundleId"] as? String, let pid = body["profileId"] as? String {
                menuBarManager?.setAppPresetProfile(bundleId: bid, profileId: pid)
                pushMappings()
            }
        case "listInstalledApps":
            scanInstalledApps()
        default:
            break
        }
    }

    /// Push the full real mapping state (7 buttons + 4 swipes + scroll speed,
    /// each with its allowed option list) to the React app via
    /// window.batonNative.setMappings. Action identity travels as rawValue —
    /// it's the UserDefaults persistence key and must round-trip unchanged.
    func pushMappings() {
        guard let mgr = menuBarManager else { return }
        let buttons: [[String: Any]] = MenuBarManager.buttonRows.map { row in
            let text = mgr.customText(forButton: row.key)
            let combo = mgr.customKeyCombo(forButton: row.key)
            return [
                "key": row.key,
                "label": row.label,
                "gesture": row.gesture,
                "action": mgr.getMapping(for: row.key).rawValue,
                "customText": text ?? "",
                "customKey": combo ?? NSNull(),
                "options": MenuBarManager.availableActions(forButton: row.key).map { action in
                    ["raw": action.rawValue,
                     "label": Self.customOptionLabel(base: action.displayName, raw: action.rawValue, text: text, combo: combo)]
                },
            ]
        }
        let swipeMeta: [(SwipeDirection, String, String)] = [
            (.up,    "上滑", "单指向上轻扫"),
            (.down,  "下滑", "单指向下轻扫"),
            (.left,  "左滑", "单指向左轻扫"),
            (.right, "右滑", "单指向右轻扫"),
        ]
        let swipes: [[String: Any]] = swipeMeta.map { (dir, label, desc) in
            let text = mgr.customText(forSwipe: dir)
            let combo = mgr.customKeyCombo(forSwipe: dir)
            return [
                "key": dir.rawValue,
                "label": label,
                "desc": desc,
                "action": mgr.getSwipeMapping(for: dir).rawValue,
                "customText": text ?? "",
                "customKey": combo ?? NSNull(),
                "options": MenuBarManager.availableSwipeActions(for: dir).map { action in
                    ["raw": action.rawValue,
                     "label": Self.customOptionLabel(base: action.displayName, raw: action.rawValue, text: text, combo: combo)]
                },
            ]
        }
        let state: [String: Any] = [
            "buttons": buttons,
            "swipes": swipes,
            "scrollSpeed": mgr.scrollSpeed.rawValue,
            "scrollSpeedOptions": ScrollSpeed.allCases.map {
                ["raw": $0.rawValue, "label": $0.displayName]
            },
            "gyro": ["gain": mgr.gyroGain, "smoothing": mgr.gyroSmoothing],
            "trackpadSensitivity": mgr.trackpadSensitivity,
            "profiles": mgr.profiles.map { p in
                [
                    "id": p.id,
                    "name": p.name,
                    "builtin": p.builtin,
                    "active": p.id == mgr.currentProfileId,
                ] as [String: Any]
            },
            "appPresets": mgr.appPresets.map { a in
                [
                    "bundleId": a.bundleId,
                    "appName": a.appName,
                    "profileId": a.profileId,
                    "iconData": (a.iconData?.base64EncodedString()) ?? NSNull(),
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.batonNative && window.batonNative.setMappings(\(json));"
        webView?.evaluateJavaScript(js) { _, _ in /* ignore */ }
    }

    /// Push { connected, deviceName, generation, battery, serial, model,
    /// lastConnectedAt, version } to the React app via window.batonNative.setState.
    /// Safe to call before the page has loaded — React installs the handler on
    /// mount and picks up the next push. Empty strings / 0 represent "unknown"
    /// (the remote isn't connected or the relevant BLE/HID property is empty).
    func pushState(connected: Bool, deviceName: String?, generation: Generation? = nil,
                   battery: Int? = nil) {
        // Pull the canonical current values from the detector when individual
        // fields aren't being changed by this call — keeps the React-side
        // devices[0] object stable across partial pushes.
        let detector = remoteDetector
        let state: [String: Any] = [
            "connected": connected,
            "deviceName": deviceName ?? detector?.persistedDeviceName ?? "Siri Remote",
            "generation": generation?.wireTag ?? detector?.persistedGeneration?.wireTag ?? "",
            "battery": battery ?? detector?.currentBattery ?? 0,
            "serial": detector?.currentSerial ?? "",
            "model": detector?.currentModel ?? "Siri Remote",
            "lastConnectedAt": detector?.lastConnectedAt.map(Self.iso8601.string(from:)) ?? "",
            "version": appVersion(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.batonNative && window.batonNative.setState(\(json));"
        webView?.evaluateJavaScript(js) { _, _ in /* ignore */ }
    }

    /// Option label for custom actions: shows the configured payload inline
    /// ("自定义文本：/compact" / "自定义按键：⌘⇧P"), or a "…" placeholder when unset.
    private static func customOptionLabel(base: String, raw: String, text: String?, combo: [String: Any]?) -> String {
        switch raw {
        case ButtonAction.customText.rawValue:
            if let t = text, !t.isEmpty {
                let clipped = t.count > 12 ? String(t.prefix(12)) + "…" : t
                return "自定义文本：\(clipped)"
            }
            return "自定义文本…"
        case ButtonAction.customKey.rawValue:
            if let label = combo?["label"] as? String, !label.isEmpty {
                return "自定义按键：\(label)"
            }
            return "自定义按键…"
        default:
            return base
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Window Content Container (drag overlay + custom traffic lights)

/// Wraps the WKWebView + a Swift-side drag overlay covering the React titlebar
/// area. WKWebView's CSS-based -webkit-app-region: drag is unreliable when
/// NSWindow uses fullSizeContentView (the native titlebar is hidden, so the
/// OS never gets the drag events). By hosting a transparent NSView on top of
/// the titlebar area that calls `window?.performDrag(with:)` on mouseDown, we
/// guarantee the window is draggable. The right side of the overlay returns
/// nil from hitTest so the 添加/设置 buttons receive their clicks through to
/// the WKWebView underneath.
///
/// Also hosts `CustomTrafficLightsView` — we hide NSWindow's native traffic
/// lights (they're vertically locked to the 28pt standard titlebar at y≈14,
/// which sits at the top of our 46pt React titlebar and looks off-center) and
/// replace them with self-drawn buttons centered at y=23.
private final class WindowContainerView: NSView {
    let dragOverlay: TitleDragOverlay
    let trafficLightsView: CustomTrafficLightsView
    private let buttonAreaRightInset: CGFloat

    init(buttonAreaRightInset: CGFloat) {
        self.buttonAreaRightInset = buttonAreaRightInset
        self.dragOverlay = TitleDragOverlay()
        self.trafficLightsView = CustomTrafficLightsView()
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(dragOverlay)
        // Traffic lights added LAST so they sit on top of the drag overlay;
        // clicks in their area go to the buttons (not the drag handler).
        addSubview(trafficLightsView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Add the WKWebView below the drag overlay in z-order so clicks land on
    /// the overlay first; hitTest on the overlay hands through to the webview
    /// for the button area.
    func attachContent(_ contentView: NSView) {
        addSubview(contentView, positioned: .below, relativeTo: dragOverlay)
        contentView.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        // WKWebView (and any other content) fills the whole frame.
        for sub in subviews where sub !== dragOverlay && sub !== trafficLightsView {
            sub.frame = bounds
        }
        // Drag overlay: top 46pt (matches .titlebar height in styles.css), full
        // width minus the right inset that reserves room for the React buttons.
        let titlebarHeight: CGFloat = 46
        let dragWidth = max(0, bounds.width - buttonAreaRightInset)
        dragOverlay.frame = NSRect(x: 0, y: bounds.height - titlebarHeight,
                                   width: dragWidth, height: titlebarHeight)
        // Custom traffic lights: vertically centered in the 46pt titlebar (y=23
        // from top, i.e. NSView y = bounds.height - 30, taking the 14pt button
        // half-height into account). Width 78pt matches React titlebar's left
        // padding (`.titlebar { padding: 0 14px 0 78px }` in styles.css).
        trafficLightsView.frame = NSRect(x: 0, y: bounds.height - 30,
                                        width: 78, height: 14)
    }
}

/// Transparent view over the React titlebar. mouseDown starts a window drag.
/// The right inset on the parent already excludes the 添加/设置 buttons; the
/// left 78pt is occupied by the traffic-lights layer above us, but since that
/// layer is later in z-order and not the dragOverlay's hitTest problem, clicks
/// there go to the buttons first.
private final class TitleDragOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Custom Traffic Lights (replace hidden native ones)

/// Container for three custom traffic-light buttons. Positioned by
/// WindowContainerView in the top-left of the React titlebar.
private final class CustomTrafficLightsView: NSView {
    private let closeButton = TrafficLightButton(kind: .close)
    private let miniButton = TrafficLightButton(kind: .miniaturize)
    private let zoomButton = TrafficLightButton(kind: .zoom)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(closeButton)
        addSubview(miniButton)
        addSubview(zoomButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // macOS traffic light spec: 14pt circles, 8pt gap, 12pt from left edge.
        let buttonSize: CGFloat = 14
        let gap: CGFloat = 8
        let leftPad: CGFloat = 12
        var x = leftPad
        let y = (bounds.height - buttonSize) / 2
        for button in [closeButton, miniButton, zoomButton] {
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + gap
        }
    }
}

/// One macOS-style traffic-light button (red/yellow/green). Hovers show the
/// ✕ / − / ⤢ symbol macOS displays. Click actions call the corresponding
/// NSWindow.perform* method, since we hide the native traffic lights.
private final class TrafficLightButton: NSButton {
    enum Kind { case close, miniaturize, zoom }
    let kind: Kind
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Zoom is a no-op for a fixed-size window (minSize == maxSize), so we
    /// grey out the green button (matching what AppKit does to the native one
    /// when its isEnabled = false): no target/action, no hover glyph.
    private var isDisabled: Bool { kind == .zoom }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        isBordered = false
        if !isDisabled {
            target = self
            action = #selector(performAction)
            updateTrackingArea()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateTrackingArea() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let opts: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInActiveApp,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    @objc private func performAction() {
        guard let w = window else { return }
        switch kind {
        case .close: w.performClose(nil)
        case .miniaturize: w.performMiniaturize(nil)
        case .zoom: w.performZoom(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS Big Sur+ traffic light colors (slightly desaturated).
        let baseColor: NSColor
        switch kind {
        case .close:
            baseColor = NSColor(srgbRed: 1.0, green: 0.373, blue: 0.388, alpha: 1)
        case .miniaturize:
            baseColor = NSColor(srgbRed: 1.0, green: 0.733, blue: 0.213, alpha: 1)
        case .zoom:
            // Window is fixed-size, so zoom is disabled — render the native
            // desaturated-greenish-gray look that AppKit uses for disabled
            // traffic lights (matches .standardWindowButton(.zoomButton)?
            // .isEnabled = false on a non-resizable window).
            baseColor = NSColor(srgbRed: 0.78, green: 0.80, blue: 0.80, alpha: 1)
        }

        // Filled circle with a thin darker stroke for depth.
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
        baseColor.setFill()
        path.fill()
        let stroke = baseColor.blended(withFraction: 0.25, of: .black) ?? baseColor
        stroke.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Disabled buttons never show a hover glyph.
        if isDisabled { return }
        guard isHovered else { return }

        // Native traffic lights draw their glyphs as thin rounded-cap paths,
        // not as font characters — emoji/Unicode glyphs are too thick and have
        // unpredictable metrics. Match the macOS Big Sur+ look: ~1pt stroke,
        // round caps, dark gray.
        let strokeColor = NSColor(white: 0.12, alpha: 0.72)
        strokeColor.setStroke()
        let g = NSBezierPath()
        g.lineWidth = 1.0
        g.lineCapStyle = .round
        g.lineJoinStyle = .round

        let w = bounds.width
        let h = bounds.height
        let cx = w / 2
        let cy = h / 2
        let pad: CGFloat = 4.0   // glyph inset from button edge

        switch kind {
        case .close:
            // ✕ — two crossing diagonals
            g.move(to: NSPoint(x: pad, y: pad))
            g.line(to: NSPoint(x: w - pad, y: h - pad))
            g.move(to: NSPoint(x: w - pad, y: pad))
            g.line(to: NSPoint(x: pad, y: h - pad))

        case .miniaturize:
            // − — single horizontal stroke through center
            g.move(to: NSPoint(x: pad, y: cy))
            g.line(to: NSPoint(x: w - pad, y: cy))

        case .zoom:
            // ⤢ — two diagonal arrows pointing into opposite corners
            g.move(to: NSPoint(x: pad, y: h - pad))
            g.line(to: NSPoint(x: pad, y: cy))
            g.move(to: NSPoint(x: pad, y: pad))
            g.line(to: NSPoint(x: cx, y: pad))
            g.move(to: NSPoint(x: w - pad, y: pad))
            g.line(to: NSPoint(x: w - pad, y: cy))
            g.move(to: NSPoint(x: w - pad, y: h - pad))
            g.line(to: NSPoint(x: cx, y: h - pad))
        }
        g.stroke()
    }
}

// MARK: - Installed app scan + available apps push

extension WebBridge {
    /// Scan /Applications and friends for .app bundles; collect bundleId + name +
    /// icon (PNG, base64). Push the result via window.batonNative.setAvailableApps
    /// so AppsPane can render the add-app picker without a separate round trip.
    func scanInstalledApps() {
        let dirs = ["/Applications", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        // NSWorkspace.icon(forFile:) + PNG encode is ~50-200ms per app; ~150 apps
        // on a typical Mac means 5-15s on the main thread — long enough to freeze
        // the menu bar. Move the whole scan to a background queue and only hop
        // back to main for the evaluateJavaScript call.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var seen: Set<String> = []
            var apps: [(bundleId: String, name: String, iconPNG: String)] = []
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
                    let png = img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                        .representation(using: .png, properties: [:])
                    apps.append((bid, name, png?.base64EncodedString() ?? ""))
                }
            }
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let payload: [[String: Any]] = apps.map { a in
                ["bundleId": a.bundleId, "appName": a.name, "iconData": a.iconPNG]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.batonNative && window.batonNative.setAvailableApps(\(json));"
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript(js) { _, _ in }
            }
        }
    }
}

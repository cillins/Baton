//
//  SettingsWindowController.swift
//  Baton
//
//  Hosts the SwiftUI settings window (was a WKWebView + WebBridge stack
//  before the native rewrite). The hand-rolled AppKit window chrome
//  survives - `WindowContainerView`, `TitleDragOverlay` - none of those
//  classes depend on web content. `attachContent` takes any NSView, so we
//  slot the SwiftUI `NSHostingView` in where the WKWebView used to go.
//  AppKit standard window buttons are hosted in the custom 46pt titlebar.
//  Baton is LSUIElement (no Dock icon by default); this controller flips
//  activation policy to .regular while the window is open so the app gets
//  a Dock icon and window chrome, then restores .accessory on close.
//

import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let vm: SettingsViewModel
    private let contentView: WindowContainerView

    init(menuBarManager: MenuBarManager, remoteDetector: RemoteDetector?) {
        self.vm = SettingsViewModel(menuBarManager: menuBarManager,
                                    remoteDetector: remoteDetector)
        // Left inset 78pt reserves space for the AppKit traffic lights;
        // Right inset reserves space for the Settings button.
        self.contentView = WindowContainerView(buttonAreaLeftInset: 78,
                                               buttonAreaRightInset: 120)

        let hosting = NSHostingController(rootView: SettingsRootView(vm: vm))
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        hosting.view.frame = contentView.bounds
        hosting.view.autoresizingMask = [.width, .height]

        // Insert hosting into the window container, then build the NSWindow
        // with the container as its content view.
        contentView.attachContent(hosting.view)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 684),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Baton"
        window.contentView = contentView
        // Fixed at the design size (1020×684) - no resizing.
        window.setContentSize(NSSize(width: 1020, height: 684))
        window.minSize = NSSize(width: 1020, height: 684)
        window.maxSize = NSSize(width: 1020, height: 684)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The view model is initialized before the NSWindow exists, so its
        // initial appearance application cannot find the window. Apply the
        // persisted choice as part of window construction as well.
        window.appearance = vm.appearance.nsAppearance
        // AppKit positions its built-in controls for a standard ~28pt title
        // bar. Baton draws a 46pt title bar, so use public, standard-window-
        // button instances in our own titlebar container and hide the
        // original off-center set.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
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
    }

    // MARK: - AppDelegate push hooks (thin forwarders; the VM owns state)

    /// Live connection-state updates from `RemoteDetector`. The VM caches the
    /// partial states so device-name updates without a connection flag still
    /// propagate cleanly.
    func pushConnectionState(connected: Bool, deviceName: String?) {
        vm.updateDevice(connected: connected, deviceName: deviceName)
    }

    /// The controller is created before RemoteDetector so the first-run guide
    /// can exist without touching protected hardware. Attach the detector once
    /// AppDelegate has prepared it.
    func attachRemoteDetector(_ detector: RemoteDetector) {
        vm.attachRemoteDetector(detector)
    }

    /// Hardware-generation update (gen1/gen2 or nil when disconnected).
    func pushGeneration(_ generation: Generation?) {
        rmDebug("🛰 pushGeneration: \(generation?.wireTag ?? "nil")")
        vm.updateDevice(connected: vm.device.connected,
                        deviceName: vm.device.name,
                        generation: generation?.wireTag)
    }

    /// BLE-battery notifications. 0 = unknown — leave it visible as "—".
    func pushBattery(_ battery: Int?) {
        rmDebug("🔋 pushBattery: \(battery.map(String.init) ?? "nil")")
        vm.updateBattery(battery)
    }

    /// User picked a new appearance in the popover; keep Swift in sync so
    /// the window background and detail text re-resolve instantly.
    func pushAppearance(_ appearance: String) {
        if let mode = AppearanceMode(rawValue: appearance) {
            vm.appearance = mode
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Return to pure menu-bar (LSUIElement) form: no Dock icon, no window.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Window Content Container (drag overlay + custom traffic lights)

/// Wraps a SwiftUI `NSHostingView` plus a Swift-side drag overlay covering
/// the titlebar area. WKWebView's CSS-based `-webkit-app-region: drag` was
/// unreliable with `fullSizeContentView` because the native titlebar is
/// hidden. Same story for the SwiftUI titlebar we ship now — even though
/// SwiftUI could provide its own drag region, performance + correctness
/// are easier to reason about with a transparent NSView on top that calls
/// `window?.performDrag(with:)` on mouseDown.
///
/// The right inset excludes the Settings button; the left 78pt hosts
/// `TrafficLightsView` which sits above us in z-order so traffic-light
/// clicks land on the buttons (not the drag handler).
///
/// Also: we hide NSWindow's native traffic lights (they're vertically locked
/// to the 28pt standard titlebar at y≈14, which sits at the top of our 46pt
/// titlebar and looks off-center) and replace them with public AppKit standard
/// window-button instances centered at y=23.
private final class WindowContainerView: NSView {
    let dragOverlay: TitleDragOverlay
    private let trafficLights = TrafficLightsView()
    private let buttonAreaLeftInset: CGFloat
    private let buttonAreaRightInset: CGFloat

    init(buttonAreaLeftInset: CGFloat, buttonAreaRightInset: CGFloat) {
        self.buttonAreaLeftInset = buttonAreaLeftInset
        self.buttonAreaRightInset = buttonAreaRightInset
        self.dragOverlay = TitleDragOverlay()
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(dragOverlay)
        addSubview(trafficLights, positioned: .above, relativeTo: dragOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Add a content view (NSHostingView hosting the SwiftUI settings root)
    /// below the drag overlay in z-order so clicks land on the overlay first.
    func attachContent(_ contentView: NSView) {
        addSubview(contentView, positioned: .below, relativeTo: dragOverlay)
        contentView.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        // SwiftUI hosting view fills the whole frame.
        for sub in subviews where sub !== dragOverlay && sub !== trafficLights {
            sub.frame = bounds
        }
        // Drag overlay: top 46pt (matches .titlebar height in styles.css),
        // between the traffic-light area (left inset) and the buttons (right
        // inset) so clicks in those areas reach their targets.
        let titlebarHeight: CGFloat = 46
        let dragX = buttonAreaLeftInset
        let dragWidth = max(0, bounds.width - buttonAreaLeftInset - buttonAreaRightInset)
        dragOverlay.frame = NSRect(x: dragX, y: bounds.height - titlebarHeight,
                                   width: dragWidth, height: titlebarHeight)
        trafficLights.frame = NSRect(x: 12, y: bounds.height - titlebarHeight,
                                     width: 54, height: titlebarHeight)
    }
}

/// Authentic AppKit traffic lights placed in Baton's taller custom titlebar.
/// `standardWindowButton(_:for:)` supplies the system artwork and interaction
/// states; this view only owns their position and forwards their actions to
/// the containing NSWindow.
private final class TrafficLightsView: NSView {
    private let closeButton: NSButton
    private let minimizeButton: NSButton
    private let zoomButton: NSButton

    override init(frame frameRect: NSRect) {
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        self.closeButton = NSWindow.standardWindowButton(.closeButton, for: mask) ?? NSButton()
        self.minimizeButton = NSWindow.standardWindowButton(.miniaturizeButton, for: mask) ?? NSButton()
        self.zoomButton = NSWindow.standardWindowButton(.zoomButton, for: mask) ?? NSButton()
        super.init(frame: frameRect)

        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeWindow)
        zoomButton.target = self
        zoomButton.action = #selector(zoomWindow)
        zoomButton.isEnabled = false

        addSubview(closeButton)
        addSubview(minimizeButton)
        addSubview(zoomButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let buttons = [closeButton, minimizeButton, zoomButton]
        let spacing: CGFloat = 8
        var x: CGFloat = 0
        for button in buttons {
            let size = button.fittingSize
            button.frame = NSRect(x: x,
                                  y: (bounds.height - size.height) / 2,
                                  width: size.width,
                                  height: size.height)
            x += size.width + spacing
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    @objc private func minimizeWindow() {
        window?.performMiniaturize(nil)
    }

    @objc private func zoomWindow() {
        window?.performZoom(nil)
    }
}

/// Transparent view over the titlebar. mouseDown starts a window drag.
/// The right inset on the parent already excludes the Settings button;
/// the left 78pt is occupied by the traffic-lights layer above us, but since
/// that layer is later in z-order and not the dragOverlay's hitTest target,
/// clicks there go to the buttons first.
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

//
//  PermissionGuide.swift
//  Baton
//
//  First-run permission onboarding. System permission requests are only
//  triggered by explicit button clicks and are presented in sequence:
//  Bluetooth first, then Accessibility and Input Monitoring.
//

import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import SwiftUI

final class PermissionGuideModel: ObservableObject {
    enum Step: Int {
        case bluetooth = 1
        case control = 2
        case complete = 3
    }

    enum BluetoothState {
        case notDetermined
        case allowed
        case denied
    }

    @Published private(set) var step: Step = .bluetooth
    @Published private(set) var bluetoothState: BluetoothState = .notDetermined
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var accessibilityRequested = false
    @Published private(set) var inputMonitoringRequested = false

    let requestBluetooth: () -> Void
    let requestAccessibility: () -> Void
    let requestInputMonitoring: () -> Void
    let finish: () -> Void

    private var pollTimer: Timer?

    init(requestBluetooth: @escaping () -> Void,
         requestAccessibility: @escaping () -> Void,
         requestInputMonitoring: @escaping () -> Void,
         finish: @escaping () -> Void) {
        self.requestBluetooth = requestBluetooth
        self.requestAccessibility = requestAccessibility
        self.requestInputMonitoring = requestInputMonitoring
        self.finish = finish
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    static var bluetoothGranted: Bool {
        CBManager.authorization == .allowedAlways
    }

    static var allPermissionsGranted: Bool {
        bluetoothGranted && AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    func beginBluetoothRequest() {
        rmDebug("🔐 Permission guide: user requested Bluetooth")
        requestBluetooth()
        refresh()
    }

    func beginAccessibilityRequest() {
        rmDebug("🔐 Permission guide: user requested Accessibility")
        accessibilityRequested = true
        requestAccessibility()
        refresh()
    }

    func beginInputMonitoringRequest() {
        rmDebug("🔐 Permission guide: user requested Input Monitoring")
        inputMonitoringRequested = true
        requestInputMonitoring()
        refresh()
    }

    func openBluetoothSettings() {
        openPrivacyPane("Privacy_Bluetooth")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    func refresh() {
        switch CBManager.authorization {
        case .allowedAlways:
            bluetoothState = .allowed
        case .denied, .restricted:
            bluetoothState = .denied
        case .notDetermined:
            bluetoothState = .notDetermined
        @unknown default:
            bluetoothState = .notDetermined
        }

        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()

        if bluetoothState != .allowed {
            step = .bluetooth
        } else if !accessibilityGranted || !inputMonitoringGranted {
            step = .control
        } else {
            step = .complete
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
                .padding(.top, 24)
            activeCard
                .padding(.top, 22)
            Spacer(minLength: 20)
            Text("Baton 只会在你点击按钮后请求对应的系统权限。")
                .font(BatonFont.text(size: 11))
                .foregroundStyle(Color.batonMeta)
        }
        .padding(.horizontal, 38)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 600, height: 450)
        .background(Color.batonSurface)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 62, height: 62)
                .accessibilityHidden(true)

            Text("设置 Baton")
                .font(BatonFont.display(size: 24, weight: .bold))
                .foregroundStyle(Color.batonFg)
            Text("按照引导逐项开启权限，避免多个系统弹窗同时出现。")
                .font(BatonFont.text(size: 13))
                .foregroundStyle(Color.batonMuted)
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            progressItem(number: 1, title: "蓝牙", complete: model.bluetoothState == .allowed,
                         active: model.step == .bluetooth)
            Rectangle()
                .fill(model.bluetoothState == .allowed ? Color.batonSuccess : Color.batonBorder)
                .frame(height: 1)
            progressItem(number: 2, title: "控制权限",
                         complete: model.accessibilityGranted && model.inputMonitoringGranted,
                         active: model.step == .control)
        }
    }

    private func progressItem(number: Int, title: String, complete: Bool, active: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(complete ? Color.batonSuccess
                          : (active ? Color.batonAccent : Color.batonBorderSoft))
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(BatonFont.mono(size: 10, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.batonMuted)
                }
            }
            .frame(width: 20, height: 20)
            Text(title)
                .font(BatonFont.text(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.batonFg : Color.batonMuted)
        }
    }

    @ViewBuilder
    private var activeCard: some View {
        switch model.step {
        case .bluetooth:
            permissionCard(
                icon: "bolt.horizontal.circle.fill",
                title: "允许蓝牙连接",
                detail: "用于发现 Siri Remote，并读取遥控器的实时电量。"
            ) {
                switch model.bluetoothState {
                case .notDetermined:
                    guideButton("继续并允许蓝牙", action: model.beginBluetoothRequest)
                case .denied:
                    VStack(spacing: 8) {
                        Text("蓝牙权限已被拒绝，请在系统设置中允许 Baton。")
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonDanger)
                        guideButton("打开蓝牙隐私设置", action: model.openBluetoothSettings)
                    }
                case .allowed:
                    EmptyView()
                }
            }

        case .control:
            permissionCard(
                icon: "cursorarrow.motionlines",
                title: "允许控制 Mac",
                detail: controlDetail
            ) {
                if !model.accessibilityGranted {
                    VStack(spacing: 8) {
                        guideButton(
                            model.accessibilityRequested ? "再次打开辅助功能设置" : "继续并允许辅助功能",
                            action: model.accessibilityRequested
                                ? model.openAccessibilitySettings
                                : model.beginAccessibilityRequest
                        )
                        if model.accessibilityRequested {
                            waitingText("开启开关后，Baton 会自动进入下一项。")
                        }
                    }
                } else if !model.inputMonitoringGranted {
                    VStack(spacing: 8) {
                        guideButton(
                            model.inputMonitoringRequested ? "再次打开输入监控设置" : "继续并允许输入监控",
                            action: model.inputMonitoringRequested
                                ? model.openInputMonitoringSettings
                                : model.beginInputMonitoringRequest
                        )
                        if model.inputMonitoringRequested {
                            waitingText("开启开关后返回 Baton，即可完成设置。")
                        }
                    }
                }
            }

        case .complete:
            permissionCard(
                icon: "checkmark.circle.fill",
                title: "准备就绪",
                detail: "所需权限均已开启，现在可以使用 Siri Remote 控制 Mac。"
            ) {
                guideButton("开始使用 Baton", action: model.finish)
            }
        }
    }

    private var controlDetail: String {
        if !model.accessibilityGranted {
            return "辅助功能用于发送按键、鼠标和滚动操作。"
        }
        return "辅助功能已开启。最后允许输入监控，以接收遥控器按键。"
    }

    private func permissionCard<Actions: View>(icon: String,
                                               title: String,
                                               detail: String,
                                               @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(model.step == .complete ? Color.batonSuccess : Color.batonAccent)
            Text(title)
                .font(BatonFont.display(size: 18, weight: .semibold))
                .foregroundStyle(Color.batonFg)
            Text(detail)
                .font(BatonFont.text(size: 12))
                .foregroundStyle(Color.batonMuted)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(Color.batonBg)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.batonBorderSoft, lineWidth: 1)
        )
    }

    private func guideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BatonFont.text(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 20)
                .frame(height: 32)
                .background(Color.batonAccent)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func waitingText(_ text: String) -> some View {
        Text(text)
            .font(BatonFont.text(size: 11))
            .foregroundStyle(Color.batonMeta)
    }
}

final class PermissionGuideWindowController: NSWindowController, NSWindowDelegate {
    let model: PermissionGuideModel

    init(requestBluetooth: @escaping () -> Void,
         requestAccessibility: @escaping () -> Void,
         requestInputMonitoring: @escaping () -> Void,
         finish: @escaping () -> Void) {
        self.model = PermissionGuideModel(
            requestBluetooth: requestBluetooth,
            requestAccessibility: requestAccessibility,
            requestInputMonitoring: requestInputMonitoring,
            finish: finish
        )
        let hosting = NSHostingController(rootView: PermissionGuideView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置 Baton"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 600, height: 450))
        // The style mask is intentionally non-resizable. Avoid assigning
        // `minSize`/`maxSize` here: those APIs constrain the outer frame
        // (including the title bar), which would shrink and clip the 450pt
        // SwiftUI content area.
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        model.refresh()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        let anotherWindowVisible = NSApp.windows.contains { $0 !== window && $0.isVisible }
        if !anotherWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

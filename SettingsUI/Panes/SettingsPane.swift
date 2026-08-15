//
//  SettingsPane.swift
//  Baton
//
//  Native general preferences, keyboard shortcut chips, and about info.
//
//  Each key/value row has the label on the left and its control or value on
//  the right.
//

import SwiftUI

struct SettingsPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CSS .dh-name: SF Pro Display 20/700, tracking -0.015em.
            Text("通用设置")
                .font(BatonFont.display(size: 20, weight: .bold, tracking: -0.3))
                .foregroundStyle(Color.batonFg)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

            GroupLabel("通用")
            GroupCard {
                kvRow("登录时启动") {
                    MacSwitch(isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { vm.setLaunchAtLogin($0) }
                    ))
                }
                DividerLine()
                kvRow("关闭主窗口时保持运行") {
                    MacSwitch(isOn: Binding(
                        get: { vm.keepRunningWhenClosed },
                        set: { vm.setKeepRunningWhenClosed($0) }
                    ))
                }
                DividerLine()
                kvRow("菜单栏显示电池百分比") {
                    MacSwitch(isOn: Binding(
                        get: { vm.showBatteryInMenuBar },
                        set: { vm.setShowBatteryInMenuBar($0) }
                    ))
                }
                DividerLine()
                kvRow("整体外观") {
                    Picker("", selection: $vm.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }

            GroupLabel("快捷键")
            GroupCard {
                kvRow("显示 / 隐藏主窗口") { kbdChips(["⌘", "Shift", "R"]) }
                DividerLine()
                kvRow("切换外观模式")         { kbdChips(["⌘", "Shift", "L"]) }
            }

            GroupLabel("遥控器麦克风")
            GroupCard {
                kvRow("功能说明") {
                    Text("可选实验功能；未安装时不影响按键、触控板和陀螺仪")
                        .font(BatonFont.text(size: 12))
                        .foregroundStyle(Color.batonFg2)
                }
                DividerLine()
                kvRow("Apple PacketLogger") {
                    HStack(spacing: 8) {
                        Text(vm.packetLoggerStatus)
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonFg2)
                        PillButton(
                            title: vm.packetLoggerReady ? "在访达中显示" : "从 Apple 获取…",
                            variant: .ghost,
                            action: vm.managePacketLogger
                        )
                    }
                }
                DividerLine()
                kvRow("Bluetooth Logging 配置") {
                    HStack(spacing: 8) {
                        Text("需单独安装；配置 3 天后自动失效")
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonFg2)
                        PillButton(
                            title: "选择并安装…",
                            variant: .ghost,
                            action: vm.installBluetoothLoggingProfile
                        )
                    }
                }
                DividerLine()
                kvRow("HCI 采集组件") {
                    HStack(spacing: 8) {
                        Text(vm.microphoneHelperStatus)
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonFg2)
                        PillButton(
                            title: vm.microphoneHelperStatus == "已启用" ? "重启组件" : "启用…",
                            variant: .ghost,
                            disabled: !vm.packetLoggerReady,
                            action: vm.enableMicrophoneCaptureHelper
                        )
                    }
                }
                DividerLine()
                kvRow("虚拟输入设备") {
                    HStack(spacing: 8) {
                        Text(vm.virtualMicrophoneInstalled ? "已安装" : "未安装")
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonFg2)
                        PillButton(
                            title: vm.virtualMicrophoneInstalled ? "卸载…" : "安装…",
                            variant: .ghost,
                            action: vm.virtualMicrophoneInstalled
                                ? vm.uninstallVirtualMicrophone
                                : vm.installVirtualMicrophone
                        )
                    }
                }
                DividerLine()
                kvRow("使用方式") {
                    HStack(spacing: 8) {
                        Text("按住 Siri 键讲话，松开停止")
                            .font(BatonFont.text(size: 12))
                            .foregroundStyle(Color.batonFg2)
                        PillButton(
                            title: "用于当前配置",
                            variant: .ghost,
                            action: vm.useRemoteMicrophoneForCurrentProfile
                        )
                    }
                }
                DividerLine()
                kvRow("同时按住快捷键") {
                    HStack(spacing: 8) {
                        KeyRecorderButton(
                            placeholder: "未设置",
                            existing: vm.remoteMicrophoneHoldKey?.label,
                            onCommit: vm.setRemoteMicrophoneHoldKey
                        )
                        if vm.remoteMicrophoneHoldKey != nil {
                            PillButton(
                                title: "清除",
                                variant: .ghost,
                                action: vm.clearRemoteMicrophoneHoldKey
                            )
                        }
                    }
                }
            }
            .onAppear { vm.refreshMicrophoneComponents() }

            GroupLabel("关于")
            GroupCard {
                kvRow("版本") {
                    Text(vm.device.version.isEmpty ? "1.0.0" : vm.device.version)
                        .font(BatonFont.mono(size: 13))
                        .foregroundStyle(Color.batonFg)
                }
                DividerLine()
                kvRow("开发者") {
                    Text("Cillin")
                        .font(BatonFont.text(size: 13))
                        .foregroundStyle(Color.batonFg)
                }
                DividerLine()
                kvRow("开发者邮箱") {
                    Link("cillinn@outlook.com", destination: URL(string: "mailto:cillinn@outlook.com")!)
                        .font(BatonFont.text(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                DividerLine()
                kvRow("GitHub 仓库") {
                    Link(destination: URL(string: "https://github.com/cillins/Baton")!) {
                        HStack(spacing: 7) {
                            GitHubMark()
                            Text("cillins/Baton")
                        }
                        .font(BatonFont.text(size: 13))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                DividerLine()
                kvRow("本地数据") {
                    Text("~/Library/Application Support/Baton")
                        .font(BatonFont.mono(size: 13))
                        .foregroundStyle(Color.batonFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private struct GitHubMark: View {
        var body: some View {
            Group {
                if let url = Bundle.main.url(forResource: "GitHubMark", withExtension: "svg"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                } else {
                    Image(systemName: "link")
                        .resizable()
                }
            }
            .scaledToFit()
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
        }
    }

    // CSS .kv: display flex, justify-content space-between, align-items
    // center, gap 12, padding 8 0, font 13. body line-height 1.45. SwiftUI's
    // default line-height is tighter than CSS, so we add a touch of padding
    // and lineSpacing to match the visual rhythm of the original.
    // NOTE: no top-divider overlay here - the .kv + .kv { border-top } rule
    // in CSS only adds a divider BETWEEN rows, not above the first. Divider
    // lines are inserted by the caller between rows.
    //
    // minHeight: 44 forces every row to the same height regardless of
    // whether the right() widget is a MacSwitch (23pt), kbdChips (~17pt),
    // or a plain Text - so rows in the same pane look uniform.
    @ViewBuilder
    private func kvRow<Right: View>(_ label: String,
                                    @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(BatonFont.text(size: 13))
                .foregroundStyle(Color.batonMuted)
            Spacer(minLength: 0)
            right()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    // CSS .kbd-row > kbd: min-width 18, padding 2 6, border 1, radius 4,
    // bg surface, mono 11px, fg-2.
    private func kbdChips(_ chips: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(BatonFont.mono(size: 11))
                    .foregroundStyle(Color.batonFg2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(minWidth: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.batonSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.batonBorder, lineWidth: 1)
                    )
            }
        }
    }

    // 0.5pt row separator matching CSS .kv + .kv { border-top: 1px solid
    // var(--border-soft) }. Inserted between rows by the caller so the
    // first row in each group doesn't pick up an unwanted top line.
    private func DividerLine() -> some View {
        Color.batonBorderSoft.frame(height: 0.5)
    }
}

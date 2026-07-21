//
//  SettingsPane.swift
//  Baton
//
//  Visual demo of the "通用设置" view: 4 toggles (视觉), keyboard shortcut
//  chips, about info. State is local @State since the real preferences
//  haven't been wired into the Swift persistence model yet — the React UI
//  also demoed these without persisting them anywhere.
//
//  Mirrors React `SettingsPane.jsx` 1:1. Each kv row has the label on the
//  left and either a MacSwitch (toggle rows) or a row of kbd chips (shortcut
//  rows) on the right, matching CSS .kv { justify-content: space-between }.
//  The footer of the 关于 GroupCard uses CSS .card-foot (margin-top 10,
//  padding-top 10, border-top 1px border-soft).
//

import SwiftUI

struct SettingsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var launchAtLogin = true
    @State private var keepRunningWhenClosed = true
    @State private var showBatteryInMenuBar = false
    @State private var autoCheckForUpdates = true

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
                    MacSwitch(isOn: $launchAtLogin)
                }
                DividerLine()
                kvRow("关闭主窗口时保持运行") {
                    MacSwitch(isOn: $keepRunningWhenClosed)
                }
                DividerLine()
                kvRow("菜单栏显示电池百分比") {
                    MacSwitch(isOn: $showBatteryInMenuBar)
                }
                DividerLine()
                kvRow("自动检查更新") {
                    MacSwitch(isOn: $autoCheckForUpdates)
                }
            }

            GroupLabel("快捷键")
            GroupCard {
                kvRow("显示 / 隐藏主窗口") { kbdChips(["⌘", "Shift", "R"]) }
                DividerLine()
                kvRow("添加遥控器")           { kbdChips(["⌘", "N"]) }
                DividerLine()
                kvRow("切换外观模式")         { kbdChips(["⌘", "Shift", "L"]) }
                DividerLine()
                kvRow("跳到当前选中设备的设置") { kbdChips(["⌘", ","]) }
            }

            GroupLabel("关于")
            GroupCard {
                kvRow("版本") {
                    Text(vm.device.version.isEmpty ? "1.0 (1)" : vm.device.version)
                        .font(BatonFont.mono(size: 13))
                        .foregroundStyle(Color.batonFg)
                }
                DividerLine()
                kvRow("开发者") {
                    Text("Baton Team")
                        .font(BatonFont.text(size: 13))
                        .foregroundStyle(Color.batonFg)
                }
                DividerLine()
                kvRow("本地数据") {
                    Text("~/Library/Application Support/Baton")
                        .font(BatonFont.mono(size: 13))
                        .foregroundStyle(Color.batonFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // CSS .card-foot: margin-top 10, padding-top 10,
                // border-top 1px border-soft, display flex,
                // justify-content flex-end, gap 8.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    PillButton(title: "检查更新", variant: .ghost, action: {})
                    PillButton(title: "查看帮助", variant: .primary, action: {})
                }
                .padding(.top, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.batonBorderSoft)
                        .frame(height: 1)
                        .padding(.top, 9)
                }
            }
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
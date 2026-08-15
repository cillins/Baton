//
//  OverviewPane.swift
//  Baton
//
//  First tab in the detail body. Two `GroupCard`s:
//   1. 连接 — status (ok/off colored) + 蓝牙 4.0/5.0
//   2. 设备信息 — model + last connected relative time
//
//  Each section is preceded by a `.group-label`.
//

import SwiftUI

struct OverviewPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel("连接", first: true)
            GroupCard {
                KeyValueRow(
                    label: "状态",
                    value: vm.device.connected ? "已连接" : "未连接",
                    valueColor: vm.device.connected ? Color.batonSuccess : Color.batonMeta,
                    mono: false
                )
                // CSS .kv + .kv { border-top: 1px solid var(--border-soft) }.
                Color.batonBorderSoft.frame(height: 0.5)
                KeyValueRow(
                    label: "方式",
                    value: vm.device.generation == "gen1" ? "蓝牙 4.0" : "蓝牙 5.0",
                    mono: false
                )
            }

            GroupLabel("设备信息")
            GroupCard {
                KeyValueRow(
                    label: "型号",
                    value: vm.device.model.isEmpty ? "Siri Remote" : vm.device.model,
                    mono: false
                )
                Color.batonBorderSoft.frame(height: 0.5)
                KeyValueRow(
                    label: "上次连接",
                    value: RelativeTime.format(vm.device.lastConnectedAt),
                    mono: false
                )
            }
        }
    }
}

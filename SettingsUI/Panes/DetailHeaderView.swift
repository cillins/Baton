//
//  DetailHeaderView.swift
//  Baton
//
//  Top of the right pane: device name + battery indicator.
//

import SwiftUI

struct DetailHeaderView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CSS .dh-text h1 + .dh-status { margin-top: 3px }. The 3px gap
            // is the status row's own top margin, not extra layout spacing —
            // so we use spacing: 0 here and add padding(.top, 3) on the row.
            Text(vm.device.name.isEmpty ? "Siri Remote" : vm.device.name)
                .font(BatonFont.display(size: 20, weight: .bold, tracking: -0.3))
                .foregroundStyle(Color.batonFg)

            HStack(spacing: 6) {
                BatteryIndicator(level: vm.device.battery)
                Text(vm.device.connected ? "已连接" : "未连接")
                    .font(BatonFont.text(size: 12))
                    .foregroundStyle(Color.batonMuted)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Insert between DetailHeader and SegmentedTabs when connected + low battery.
struct LowBatteryAlert: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        if vm.device.connected && vm.device.battery > 0 && vm.device.battery < 20 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.batonWarn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("电量不足。")
                        .font(BatonFont.text(size: 13).weight(.semibold))
                        .foregroundStyle(Color.batonFg)
                    Text("\(vm.device.name) 电量仅剩 \(vm.device.battery)%，请尽快为其充电，以免使用中断开连接。")
                        .font(BatonFont.text(size: 12))
                        .foregroundStyle(Color.batonMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Color.batonWarn.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(Color.batonWarn.opacity(0.30), lineWidth: 1)
            )
            .padding(.top, 16)
        }
    }
}

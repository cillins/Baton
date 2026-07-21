//
//  SensitivityPane.swift
//  Baton
//
//  Sensitivity tab. Two `GroupCard`s:
//
//   1. 触控板 — 光标灵敏度 (100–1000, step 10), commit on slider release.
//   2. 陀螺仪 — only when gen1 remote is connected, gain (0.5–6 step 0.1) +
//      smoothing (0–100 %). Sliders commit once.
//
//  Mirrors React SensitivityPane.jsx 1:1.
//

import SwiftUI

struct SensitivityPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel("触控板", first: true)
            GroupCard {
                SliderRow(
                    label: "光标灵敏度",
                    value: Binding(
                        get: { Double(vm.trackpadSensitivity) },
                        set: { vm.trackpadSensitivity = Int($0) }
                    ),
                    range: 100...1000,
                    step: 10,
                    format: { "\(Int($0))" },
                    onCommit: { v in
                        vm.setTrackpadSensitivity(Int(v))
                    }
                )
                note("调整双指移动时光标的响应幅度；数值越大移动越快。")
            }

            if vm.device.generation == "gen1" {
                GroupLabel("陀螺仪（一代遥控器）")
                GroupCard {
                    SliderRow(
                        label: "拖动灵敏度",
                        value: $vm.gyroGain,
                        range: 0.5...6.0,
                        step: 0.1,
                        format: { String(format: "%.1f", $0) },
                        onCommit: { v in
                            vm.setGyro(gain: v, smoothing: vm.gyroSmoothing)
                        }
                    )
                    // CSS .kv + .kv { border-top: 1px solid var(--border-soft) }.
                    // Restored after the previous edit removed it - this IS the
                    // correct per-CSS separator between adjacent .kv rows.
                    Color.batonBorderSoft.frame(height: 0.5)
                    SliderRow(
                        label: "防抖强度",
                        value: Binding(
                            get: { Double(vm.gyroSmoothing) },
                            set: { vm.gyroSmoothing = Int($0) }
                        ),
                        range: 0...100,
                        step: 1,
                        format: { "\(Int($0))%" },
                        onCommit: { v in
                            vm.setGyro(gain: vm.gyroGain, smoothing: Int(v))
                        }
                    )
                    note("按住触控板转动遥控器；相同转动角度对应相同光标距离。")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        // CSS .map-note: margin-top 14px, font 12/--muted.
        Text(text)
            .font(BatonFont.text(size: 12))
            .foregroundStyle(Color.batonMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
    }
}

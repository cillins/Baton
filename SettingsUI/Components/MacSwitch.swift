//
//  MacSwitch.swift
//  Baton
//
//  CSS .sw reproduction: 38x23 pill, 19x19 knob, 4px padding. Off-state uses a
//  translucent fg overlay (rgba 20% transparent); on-state uses --success
//  green. Knob offset = (pillWidth - knobWidth - 4) = 15 on the standard
//  variant; 12 on the .sm variant. Animate via standard easeInOut(0.22) —
//  matches the CSS --motion-base transition.
//

import SwiftUI

struct MacSwitch: View {
    @Binding var isOn: Bool
    var small: Bool = false

    private var pillW: CGFloat { small ? 32 : 38 }
    private var pillH: CGFloat { small ? 20 : 23 }
    private var knobSize: CGFloat { small ? 16 : 19 }
    private var offsetOn: CGFloat { small ? 12 : 15 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? Color.batonSuccess : Color.batonFg.opacity(0.20))
                .frame(width: pillW, height: pillH)
            Circle()
                .fill(Color.batonBg)
                .frame(width: knobSize, height: knobSize)
                // CSS --shadow-popover: 0 1px 3px rgba(0,0,0,0.25).
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                .offset(x: isOn ? offsetOn : 2, y: 0)
        }
        .frame(width: pillW, height: pillH)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .animation(.easeInOut(duration: Motion.base), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel("开关")
        .accessibilityValue(isOn ? "开" : "关")
    }
}
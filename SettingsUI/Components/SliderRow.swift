//
//  SliderRow.swift
//  Baton
//
//  A `.kv.gyro-slider`-style row with the
//  label on the left and a slider + monospaced value chip on the right
//  (CSS `.kv { display: flex; justify-content: space-between }` +
//  `.gyro-slider-ctl { display: inline-flex; gap: 10 }` +
//  `.gyro-slider-val { min-width: 44 }`).
//
//  Use a local `@State draft` so dragging updates the UI without writing
//  to UserDefaults on every tick; commit once on `editingChanged == false`.
//

import SwiftUI

struct SliderRow: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    var disabled: Bool = false
    var onCommit: ((Double) -> Void)? = nil

    @State private var draft: Double = 0
    @State private var didInit = false

    var body: some View {
        // CSS .kv { display: flex; justify-content space-between; align-items
        // center; gap 12; padding 8 0 }. body line-height 1.45. SwiftUI
        // line-height is tighter, so 10pt vertical padding + 3pt lineSpacing
        // gives the same visual rhythm as the original.
        HStack(alignment: .center, spacing: 12) {
            // CSS .kv .k { color: var(--muted) }.
            Text(label)
                .font(BatonFont.text(size: 13))
                .foregroundStyle(Color.batonMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { draft },
                        set: { newVal in
                            // Supplying `step:` to SwiftUI's macOS Slider
                            // makes AppKit draw one tick for every step. With
                            // 50-100 steps those ticks merge into a distracting
                            // dotted line below the track. Snap manually so the
                            // value remains discrete without showing tick marks.
                            let snapped = range.lowerBound
                                + ((newVal - range.lowerBound) / step).rounded() * step
                            let clamped = min(range.upperBound, max(range.lowerBound, snapped))
                            draft = clamped
                            value = clamped
                        }
                    ),
                    in: range
                ) {
                    EmptyView()
                } onEditingChanged: { editing in
                    if !editing {
                        onCommit?(draft)
                    }
                }
                .disabled(disabled)
                .frame(width: 180)
                Text(format(draft))
                    .font(BatonFont.mono(size: 12).weight(.medium))
                    .foregroundStyle(Color.batonFg2)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        // No top-divider here - the parent inserts DividerLine views BETWEEN
        // rows (matching CSS .kv + .kv { border-top }). No minHeight: the
        // slider is a system component that's 21pt tall - forcing it into a
        // 44pt frame would make it "float" with empty space above/below.
        // The natural height (41pt) matches CSS (~37pt with line-height 1.0)
        // and looks tighter than the stretched version.
        .onAppear {
            if !didInit {
                draft = value
                didInit = true
            }
        }
        .onChange(of: value) { newVal in
            // External changes (e.g. profile switch) pull draft back in sync.
            if abs(newVal - draft) > .ulpOfOne {
                draft = newVal
            }
        }
    }
}

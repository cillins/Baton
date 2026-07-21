//
//  BatteryIndicator.swift
//  Baton
//
//  SVG-style battery shell + fill bar + tip + percentage label. Matches the
//  React DetailHeader's `.batt-ind` markup 1:1:
//
//    <svg viewBox="0 0 26 14" width="22" height="12">
//      <rect class="batt-shell" x="1" y="1" width="22" height="12" rx="2.2" />
//      <rect class="batt-fill"  x="3" y="3" width={fillW} height="8" rx="1" />
//      <rect class="batt-tip"   x="23.5" y="4.5" width="2" height="5" rx="0.6" />
//    </svg>
//
//  Uses direct shapes (RoundedRectangle / Rectangle) instead of Canvas —
//  Canvas was rendering unreliably on macOS for this small icon. Direct
//  shapes scale the SVG geometry to the display size (22x12) at draw time.
//

import SwiftUI

struct BatteryIndicator: View {
    /// 0..100; 0 means "unknown" (BLE hasn't notified yet).
    var level: Int

    var body: some View {
        HStack(spacing: 6) {
            // Display size 22x12. SVG viewBox is 26x14, so scale = 22/26 (x)
            // and 12/14 (y). Apply uniformly to keep the shape from looking
            // squashed; close enough to CSS for a 22pt icon.
            ZStack(alignment: .topLeading) {
                // Shell: rect(1, 1, 22, 12), rx 2.2 → screen rect
                // (0.846, 0.857, 18.6, 10.3), rx 1.86. Stroke only.
                RoundedRectangle(cornerRadius: 1.86, style: .continuous)
                    .stroke(Color.batonMeta.opacity(0.85), lineWidth: 1.4)
                    .frame(width: 18.6, height: 10.3)
                    .offset(x: 0.85, y: 0.86)

                // Fill: rect(3, 3, fillW, 8), rx 1 — only when known.
                // fillW = max(1.5, batt/100 * 18), rounded to 0.1 in viewBox.
                if level > 0 {
                    let rawV = CGFloat(level) / 100 * 18
                    let fillW = max(1.5, (rawV * 10).rounded() / 10)
                    // Screen: x=2.54, y=2.57, w=fillW*0.846, h=6.86, rx 0.85.
                    RoundedRectangle(cornerRadius: 0.85, style: .continuous)
                        .fill(fillColor)
                        .frame(width: fillW * 0.846, height: 6.86)
                        .offset(x: 2.54, y: 2.57)
                }

                // Tip: rect(23.5, 4.5, 2, 5), rx 0.6 → screen rect
                // (19.89, 3.86, 1.69, 4.29), rx 0.51. Fill only.
                RoundedRectangle(cornerRadius: 0.51, style: .continuous)
                    .fill(Color.batonMeta.opacity(0.85))
                    .frame(width: 1.69, height: 4.29)
                    .offset(x: 19.89, y: 3.86)
            }
            .frame(width: 22, height: 12)

            // CSS .batt-pct: font-family mono, tabular-nums. Color inherits
            // from .dh-status -> --muted. No level-based color override.
            Text(level == 0 ? "-" : "\(level)%")
                .font(BatonFont.mono(size: 12))
                .foregroundStyle(Color.batonMuted)
                .monospacedDigit()
        }
    }

    private var fillColor: Color {
        if level == 0 { return Color.batonMeta }
        if level < 20 { return Color.batonWarn }
        return Color.batonSuccess
    }
}

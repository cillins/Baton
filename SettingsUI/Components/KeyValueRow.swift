//
//  KeyValueRow.swift
//  Baton
//
//  One row in a `.group` — a left-aligned label and right-aligned value with a
//  1px border-soft separator below. Matches CSS `.kv` from styles.css.
//

import SwiftUI

struct KeyValueRow: View {
    var label: String
    var value: String
    // CSS .kv .v has no explicit color (inherits .kv -> body -> --fg).
    var valueColor: Color = .batonFg
    var mono: Bool = true

    var body: some View {
        // CSS .kv: flex space-between, align-items center, gap 12,
        // padding 8 0, font 13. .k muted, .v right-aligned, white-space
        // nowrap with ellipsis on overflow.
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(BatonFont.text(size: 13))
                .foregroundStyle(Color.batonMuted)
            Spacer(minLength: 0)
            // CSS .kv .v: text-align right. CSS .kv .v.ok: color success,
            // font-weight 600; CSS .kv .v.off: color meta.
            Text(value)
                .font(mono ? BatonFont.mono(size: 13).weight(.medium) : BatonFont.text(size: 13))
                .fontWeight(valueColor == Color.batonSuccess ? .semibold : .regular)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
        // No top-divider here - the parent inserts DividerLine views BETWEEN
        // rows (matching CSS .kv + .kv { border-top }). This keeps the first
        // row in each group free of an unwanted top line.
        // minHeight: 44 keeps rows uniform regardless of the value widget's
        // intrinsic height (so GroupCards don't get jagged right edges).
        .frame(minHeight: 44)
    }
}

struct KeyValueRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.batonBorderSoft)
            .frame(height: 0.5)
    }
}
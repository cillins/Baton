//
//  SegmentedTabs.swift
//  Baton
//
//  Custom segmented control matching CSS .seg: an inset track (--surface bg +
//  --border-soft 1px stroke + radius 10 + padding 2) with per-button pills
//  carrying --shadow-card + --bg + font 13/600 when active. macOS 12's
//  .segmented Picker can't reproduce this look (no inset surface track),
//  so we draw it ourselves.
//

import SwiftUI

struct SegmentedTabs<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(BatonFont.text(size: 13,
                                             weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? Color.batonFg : Color.batonFg2)
                        .padding(.horizontal, 16)
                        // CSS text inherits body line-height: 1.45. SwiftUI's
                        // intrinsic 13pt text is several points shorter, so a
                        // fixed 30pt pill maintains the intended control height.
                        .frame(height: 30)
                        .background(
                            Group {
                                if selection == item {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.batonBg)
                                        .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
                                        .shadow(color: .black.opacity(0.04), radius: 0, x: 0, y: 0)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.batonSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.batonBorderSoft, lineWidth: 1)
        )
    }
}

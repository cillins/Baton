//
//  GroupCard.swift
//  Baton
//
//  Reusable rounded container with the design-system surface, border, and padding.
//  Matches CSS `.group` (background --bg, 1px border-soft, radius 12, padding
//  14 16). Used by every pane as the primary content surface.
//

import SwiftUI

struct GroupCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Wrap content in a VStack so the background/border/clip applies
        // to the WHOLE group, not each individual row. Without this wrapper,
        // a `@ViewBuilder { row1(); row2(); row3() }` would be a TupleView
        // and modifiers would apply to each row separately, making every
        // row look like its own little card.
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, padding + 2)
        .padding(.vertical, padding)
        // CSS .group: bg --bg, border-soft, radius --radius-md, padding 14/16.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batonBg)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.batonBorderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
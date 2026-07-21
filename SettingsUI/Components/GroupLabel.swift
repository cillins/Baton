//
//  GroupLabel.swift
//  Baton
//
//  Section label that appears above every GroupCard. Mirrors CSS
//  .group-label: margin 18px 4px 6px, font 12px, weight 600, color fg-2.
//
//  CSS .pane > .group-label:first-child { margin-top: 0 } - when a pane
//  starts directly with a group-label (no title before it), the first
//  label has no top margin. Pass `first: true` in that case.
//

import SwiftUI

struct GroupLabel: View {
    let text: String
    var first: Bool = false
    init(_ text: String, first: Bool = false) {
        self.text = text
        self.first = first
    }

    var body: some View {
        Text(text)
            .font(BatonFont.text(size: 12).weight(.semibold))
            .foregroundStyle(Color.batonFg2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, first ? 0 : 18)
            .padding(.bottom, 6)
    }
}

/// Variant for `.modal-body` where the surrounding padding is different
/// (CSS: `.modal-body .group-label { margin: 12 2 8 }`, first-child margin-top 0).
/// Pass `first: true` for the first group-label in the modal body so the
/// top margin is dropped (matches `:first-child` selector in CSS).
struct ModalGroupLabel: View {
    let text: String
    var first: Bool = false
    init(_ text: String, first: Bool = false) {
        self.text = text
        self.first = first
    }

    var body: some View {
        Text(text)
            .font(BatonFont.text(size: 12).weight(.semibold))
            .foregroundStyle(Color.batonFg2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, first ? 0 : 12)
            .padding(.bottom, 8)
    }
}
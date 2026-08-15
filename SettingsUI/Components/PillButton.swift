//
//  PillButton.swift
//  Baton
//
//  Matches CSS `.abtn` / `.abtn-ghost` from styles.css:400-415. Used for
//  action buttons in the profile footer, the app picker toggle, and the
//  about panel in SettingsPane.
//
//  Primary (`.abtn`): bg --accent, color --accent-on, padding 6 16, radius
//  8, no border, font 13/500. Hover darkens to --accent-hover; active
//  scales 0.97. Disabled at 0.55 opacity.
//
//  Ghost (`.abtn-ghost`): transparent bg, color --accent, border 1px
//  --border, radius 8. Hover tints bg with accent at 7% + border -> accent.
//

import SwiftUI

struct PillButton: View {
    enum Variant { case primary, ghost }

    let title: String
    var variant: Variant = .primary
    var disabled: Bool = false
    var action: () -> Void

    @State private var hovering = false

    private var hoverBg: Color {
        switch variant {
        case .primary:
            // .abtn:hover { background: var(--accent-hover) }
            return Color.batonAccentHover
        case .ghost:
            // .abtn-ghost:hover { background: color-mix(in oklab, var(--accent) 7%, transparent) }
            return Color.batonAccent.opacity(0.07)
        }
    }

    private var hoverBorder: Color {
        switch variant {
        case .primary: return Color.clear
        case .ghost:
            // .abtn-ghost:hover { border-color: var(--accent) }
            return Color.batonAccent
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BatonFont.text(size: 13).weight(.medium))
                .foregroundStyle(variant == .primary ? Color.batonAccentOn : Color.batonAccent)
                .padding(.horizontal, 16)
                // Keep enough vertical padding so native action buttons do
                // not look compressed.
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(disabled ? Color.clear
                             : (hovering ? hoverBg
                                : (variant == .primary ? Color.batonAccent : Color.clear)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(disabled ? Color.clear
                               : (hovering && variant == .ghost ? hoverBorder
                                  : (variant == .primary ? Color.clear : Color.batonBorder)),
                                lineWidth: 1)
                )
                .opacity(disabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .contentShape(Rectangle())
    }
}

/// Small action button used inside ProfileRow / PresetRow. Matches CSS
/// `.prof-icon-btn`: padding 4 10, radius 8, color accent, font 12/medium.
/// `.danger` flips color to --danger. Disabled flips to --meta.
/// Hover: accent-7% tint bg (danger-7% for danger variant).
struct IconActionButton: View {
    enum Tone { case `default`, danger }

    let title: String
    var tone: Tone = .default
    var disabled: Bool = false
    var tooltip: String? = nil
    var action: () -> Void

    @State private var hovering = false

    private var textColor: Color {
        if disabled { return Color.batonMeta }
        return tone == .danger ? Color.batonDanger : Color.batonAccent
    }

    private var hoverBg: Color {
        // .prof-icon-btn:hover { background: color-mix(accent 7%, transparent) }
        // .danger:hover { background: color-mix(danger 7%, transparent) }
        tone == .danger ? Color.batonDanger.opacity(0.07) : Color.batonAccent.opacity(0.07)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BatonFont.text(size: 12).weight(.medium))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(hovering && !disabled ? hoverBg : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .help(tooltip ?? "")
    }
}

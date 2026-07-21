//
//  MapRow.swift
//  Baton
//
//  One row inside the profile-edit modal (or the in-pane mapping list):
//  left-aligned label, gesture hint, action Picker(.menu), then inline the
//  custom-text field OR key recorder when the user picks a Custom action.
//
//  Matches CSS .map-row / .map-key / .map-gesture / .map-sel / .map-custom
//  from styles.css:626-660. The custom editor slots in below the row, not
//  to the right — that matches `ProfileEditModal.jsx:181`.
//

import AppKit
import SwiftUI

/// The mapping editor uses the same `1.2fr 0.8fr 1fr` grid as the former
/// web UI. `layoutPriority` is not a fractional-width API: when it was used
/// here, the first column won the entire proposal and collapsed the gesture
/// and action columns. This small layout view computes the three widths from
/// the offered row width while remaining compatible with macOS 12.
struct MappingColumns<First: View, Second: View, Third: View>: View {
    var height: CGFloat
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second
    @ViewBuilder var third: () -> Third

    private let spacing: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let columnsWidth = max(0, proxy.size.width - spacing * 2)
            HStack(spacing: spacing) {
                first()
                    .frame(width: columnsWidth * 0.4, alignment: .leading)
                second()
                    .frame(width: columnsWidth * (0.8 / 3.0), alignment: .leading)
                third()
                    .frame(width: columnsWidth / 3.0, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: height, alignment: .leading)
        }
        .frame(height: height)
    }
}

struct SelectFieldOption: Equatable {
    let id: String
    let title: String
}

/// Native AppKit popup wrapped at the smallest possible boundary. SwiftUI
/// owns `selection` and the option list; NSPopUpButton owns pointer hit
/// testing and menu presentation, which avoids the unreliable transparent
/// SwiftUI Menu overlays used by the first migration.
struct SelectField: NSViewRepresentable {
    let selection: String
    let options: [SelectFieldOption]
    var disabled: Bool = false
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.focusRingType = .none
        button.font = NSFont.systemFont(ofSize: 13)
        button.alignment = .left
        button.cell?.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect

        let currentOptions = button.itemArray.map {
            SelectFieldOption(id: ($0.representedObject as? String) ?? "", title: $0.title)
        }
        if currentOptions != options {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
                button.lastItem?.representedObject = option.id
            }
        }

        if let index = button.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == selection
        }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        button.isEnabled = !disabled
        button.setAccessibilityLabel(button.titleOfSelectedItem ?? selection)
    }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            onSelect(id)
        }
    }
}

struct MapRow: View {
    var label: String
    var gesture: String
    @Binding var action: String
    var options: [ButtonOptionVM]
    var readOnly: Bool = false

    // Custom action wiring (only used when `action` is one of "Custom Text"
    // / "Custom Key"). Mutating these commits through the same VM paths the
    // pickers do.
    var customText: Binding<String>?
    var customKey: Binding<KeyCombo?>?
    var onSetCustomText: ((String) -> Void)?
    var onSetCustomKey: ((KeyCombo) -> Void)?
    var onClearCustomKey: (() -> Void)?

    private var isCustomText: Bool { action == "Custom Text" }
    private var isCustomKey:  Bool { action == "Custom Key" }

    var body: some View {
        // CSS .map-row: display grid, grid-template-columns 1.2fr 0.8fr 1fr,
        // gap 14, align-items center, padding 10 2. Adjacent rows share a
        // border-soft top divider.
        VStack(alignment: .leading, spacing: 0) {
            MappingColumns(height: 28) {
                Text(label)
                    .font(BatonFont.text(size: 13).weight(.semibold))
                    .foregroundStyle(Color.batonFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            } second: {
                Text(gesture)
                    .font(BatonFont.text(size: 12))
                    .foregroundStyle(Color.batonMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            } third: {
                MenuPicker(
                    selection: $action,
                    options: options,
                    disabled: readOnly
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
            if isCustomText, let binding = customText, !readOnly {
                customEditor {
                    // CSS .prof-input: padding 5 8, bg --bg, border 1px --border,
                    // radius --radius-sm (8), font 13px, color --fg.
                    // .map-custom .prof-input { flex: 1 } overrides the 140px width.
                    TextField(
                        "输入要键入的文本，如 /compact 或一段提示词",
                        text: binding,
                        onCommit: { onSetCustomText?(binding.wrappedValue) }
                    )
                    .textFieldStyle(.plain)
                    .font(BatonFont.text(size: 13))
                    .foregroundStyle(Color.batonFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(customEditorBackground)
                }
            }
            if isCustomKey, let keyBinding = customKey, !readOnly {
                customEditor {
                    KeyRecorderButton(
                        existing: keyBinding.wrappedValue?.label,
                        onCommit: { combo in
                            keyBinding.wrappedValue = combo
                            onSetCustomKey?(combo)
                        },
                        onClear: {
                            keyBinding.wrappedValue = nil
                            onClearCustomKey?()
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func customEditor<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // CSS .map-custom: display flex, align-items center, gap 8,
        // padding 0 2 10 (top 0, right 2, bottom 10, left 2).
        HStack(spacing: 8) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    private var customEditorBackground: some View {
        // CSS .prof-input: border 1px --border, radius --radius-sm (8),
        // bg --bg.
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Color.batonBg)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(Color.batonBorder, lineWidth: 1)
            )
    }
}

/// A reusable Picker(.menu) styled to match CSS .map-sel: 13px text, padding
/// 6 10, radius 6, border-soft 1px stroke, surface bg. Hover/active states
/// mirror React's `.map-sel:hover` / `.map-sel:focus`.
private struct MenuPicker: View {
    @Binding var selection: String
    var options: [ButtonOptionVM]
    var disabled: Bool = false

    var body: some View {
        SelectField(
            selection: selection,
            options: options.map { SelectFieldOption(id: $0.raw, title: $0.label) },
            disabled: disabled,
            onSelect: { selection = $0 }
        )
        .frame(height: 28)
        .fixedSize(horizontal: false, vertical: true)
    }
}

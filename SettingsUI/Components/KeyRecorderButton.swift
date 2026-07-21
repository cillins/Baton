//
//  KeyRecorderButton.swift
//  Baton
//
//  Records a chord (keyCode + modifiers) and reports it as a `KeyCombo`.
//
//  Matches React `ProfileEditModal.jsx:KeyRecorderButton` exactly:
//   - rec-label: 13px, muted, min-width 64. `.has-combo`: color inherit (fg),
//     weight 600.
//   - Button: `.abtn` (primary) when recording, `.abtn-ghost` when idle.
//     Label: "录制" idle, "按下组合键…（Esc 取消）" recording.
//
//  Implementation note: the React version needed a DOM-to-CGKeyCode table
//  because `event.code` is KeyboardEvent.code (string) and Swift only knows
//  CGKeyCode. In AppKit, `NSEvent.keyCode` IS the CGKeyCode already, so we
//  can skip the mapping table entirely. `event.charactersIgnoringModifiers`
//  gives us the glyph to display (single chars for letters/digits, special
//  keys like ⏎/⎋/←/-> are recognized by their keyCode instead).
//
//  Esc with no modifiers cancels. The same glyph normalization as the
//  React side (`"↩" -> "⏎"`, `"⎋" -> "esc"`) runs through `MenuBarManager`'s
//  dict so a recorded combo renders identically to the preset that maps to
//  the same key.
//

import SwiftUI
import AppKit
import Carbon

struct KeyRecorderButton: View {
    var placeholder: String = "未设置"
    var existing: String?
    var onCommit: (KeyCombo) -> Void
    var onClear: (() -> Void)?  // accepted for API stability; not rendered (matches React)

    @State private var recording = false

    var body: some View {
        HStack(spacing: 8) {
            // CSS .rec-label: font-size 13, color muted, min-width 64.
            // .has-combo: color inherit (fg), font-weight 600.
            Text(existing ?? placeholder)
                .font(existing != nil
                      ? BatonFont.text(size: 13).weight(.semibold)
                      : BatonFont.text(size: 13))
                .foregroundStyle(existing != nil ? Color.batonFg : Color.batonMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 64, alignment: .leading)

            // CSS .abtn (recording) / .abtn-ghost (idle): padding 6 16,
            // radius 8, font 13/500. Primary: accent bg, accent-on text.
            // Ghost: transparent bg, accent text, 1px border.
            Button(recording ? "按下组合键…（Esc 取消）" : "录制") {
                recording.toggle()
            }
            .buttonStyle(.plain)
            .font(BatonFont.text(size: 13).weight(.medium))
            .foregroundStyle(recording ? Color.batonAccentOn : Color.batonAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(recording ? Color.batonAccent : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(recording ? Color.clear : Color.batonBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .background(KeyRecorderMonitor(active: recording) { combo in
            recording = false
            onCommit(combo)
        } onCancel: {
            recording = false
        })
    }
}

/// Monitors `NSEvent.local` for key events while installed. Notified with a
/// `KeyCombo` on a valid press, or with nothing on Esc-no-mods. Returning
/// nil from the local monitor swallows the event so the underlying text
/// input (if any) doesn't see the recording keystroke.
private struct KeyRecorderMonitor: NSViewRepresentable {
    var active: Bool
    var onComplete: (KeyCombo) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(active: active, onComplete: onComplete, onCancel: onCancel)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(active: active, onComplete: onComplete, onCancel: onCancel)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var active = false
        private var onComplete: ((KeyCombo) -> Void)?
        private var onCancel: (() -> Void)?

        func attach(active: Bool,
                    onComplete: @escaping (KeyCombo) -> Void,
                    onCancel: @escaping () -> Void) {
            if active && self.monitor == nil {
                self.onComplete = onComplete
                self.onCancel = onCancel
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    if Self.isOnlyModifier(event) { return event }
                    if event.keyCode == kVK_Escape
                        && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                        self.onCancel?()
                        return nil
                    }
                    let mods = Self.modifierNames(event.modifierFlags)
                    let glyph = Self.glyph(event: event)
                    let label = mods.map { Self.modGlyph($0) }.joined() + glyph
                    let combo = KeyCombo(
                        keyCode: Int(event.keyCode),
                        modifiers: mods,
                        label: label
                    )
                    self.onComplete?(combo)
                    return nil
                }
            }
            if !active, self.monitor != nil {
                detach()
            }
            self.active = active
            if active {
                self.onComplete = onComplete
                self.onCancel = onCancel
            }
        }

        func detach() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func isOnlyModifier(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 54, 55: return true   // cmd
            case 56, 60: return true   // shift (left/right)
            case 58, 61: return true   // opt
            case 59, 62: return true   // ctrl
            default: return false
            }
        }

        private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
            var out: [String] = []
            if flags.contains(.control) { out.append("ctrl") }
            if flags.contains(.option) { out.append("opt") }
            if flags.contains(.shift) { out.append("shift") }
            if flags.contains(.command) { out.append("cmd") }
            return out
        }

        private static func modGlyph(_ name: String) -> String {
            switch name {
            case "ctrl": return "⌃"
            case "opt":  return "⌥"
            case "shift": return "⇧"
            case "cmd":  return "⌘"
            default: return ""
            }
        }

        private static func glyph(event: NSEvent) -> String {
            let keyCode = Int(event.keyCode)
            switch keyCode {
            case kVK_Return:        return "⏎"
            case kVK_Tab:           return "⇥"
            case kVK_Delete:        return "⌫"
            case kVK_ForwardDelete: return "⌦"
            case kVK_Escape:        return "esc"
            case kVK_UpArrow:       return "↑"
            case kVK_DownArrow:     return "↓"
            case kVK_LeftArrow:     return "←"
            case kVK_RightArrow:    return "->"
            case kVK_Space:         return "␣"
            default:
                if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                    let c = chars.first!
                    if c.isLetter || c.isNumber {
                        return String(c.uppercased())
                    }
                    return String(c)
                }
                return "?"
            }
        }
    }
}

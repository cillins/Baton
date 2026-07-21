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

/// Monitors ordinary keyDown events locally. Top-row NX_SYSDEFINED keys are
/// intercepted earlier and forwarded by MediaKeyInterceptor while recording.
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
        private var eventTap: CFMachPort?
        private var eventTapSource: CFRunLoopSource?
        private var active = false
        private var onComplete: ((KeyCombo) -> Void)?
        private var onCancel: (() -> Void)?

        func attach(active: Bool,
                    onComplete: @escaping (KeyCombo) -> Void,
                    onCancel: @escaping () -> Void) {
            if active && self.monitor == nil && self.eventTap == nil {
                self.onComplete = onComplete
                self.onCancel = onCancel
                if !startEventTap() {
                    self.monitor = NSEvent.addLocalMonitorForEvents(
                        matching: [.keyDown, .flagsChanged]
                    ) { [weak self] event in
                        guard let self else { return event }
                        return self.capture(event) ? nil : event
                    }
                }
                MediaKeyInterceptor.recordingSystemKeyHandler = { [weak self] nxCode in
                    guard let self else { return }
                    self.onComplete?(
                        KeyCombo(
                            keyCode: -1,
                            modifiers: [],
                            label: Self.systemKeyLabel(nxCode),
                            systemKeyCode: Int(nxCode)
                        )
                    )
                }
            }
            if !active, self.monitor != nil || self.eventTap != nil {
                detach()
            }
            self.active = active
            if active {
                self.onComplete = onComplete
                self.onCancel = onCancel
            }
        }

        func detach() {
            MediaKeyInterceptor.recordingSystemKeyHandler = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
            eventTap = nil
            eventTapSource = nil
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func startEventTap() -> Bool {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let coordinator = Unmanaged<Coordinator>.fromOpaque(refcon).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = coordinator.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    guard let nsEvent = NSEvent(cgEvent: event) else {
                        return Unmanaged.passUnretained(event)
                    }
                    return coordinator.capture(nsEvent) ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { return false }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                return false
            }
            eventTap = tap
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        /// Returns true when the event is part of capture and should not reach
        /// the previously focused app/global-hotkey owner.
        private func capture(_ event: NSEvent) -> Bool {
            if event.type == .flagsChanged {
                guard event.keyCode == kVK_Function,
                      event.modifierFlags.contains(.function) else { return false }
                onComplete?(KeyCombo(keyCode: kVK_Function, modifiers: ["fn"], label: "fn"))
                return true
            }
            guard event.type == .keyDown else { return false }
            if Self.isOnlyModifier(event) { return false }
            if event.keyCode == kVK_Escape,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                onCancel?()
                return true
            }
            let modifiers = Self.modifierNames(event.modifierFlags)
            let label = modifiers.map { Self.modGlyph($0) }.joined() + Self.glyph(event: event)
            onComplete?(KeyCombo(
                keyCode: Int(event.keyCode),
                modifiers: modifiers,
                label: label
            ))
            return true
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
            case kVK_F1:            return "F1"
            case kVK_F2:            return "F2"
            case kVK_F3:            return "F3"
            case kVK_F4:            return "F4"
            case kVK_F5:            return "F5"
            case kVK_F6:            return "F6"
            case kVK_F7:            return "F7"
            case kVK_F8:            return "F8"
            case kVK_F9:            return "F9"
            case kVK_F10:           return "F10"
            case kVK_F11:           return "F11"
            case kVK_F12:           return "F12"
            case kVK_F13:           return "F13"
            case kVK_F14:           return "F14"
            case kVK_F15:           return "F15"
            case kVK_F16:           return "F16"
            case kVK_F17:           return "F17"
            case kVK_F18:           return "F18"
            case kVK_F19:           return "F19"
            case kVK_F20:           return "F20"
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
            case kVK_Home:          return "Home"
            case kVK_End:           return "End"
            case kVK_PageUp:        return "Page Up"
            case kVK_PageDown:      return "Page Down"
            case kVK_Help:          return "Help"
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

        private static func systemKeyLabel(_ code: Int32) -> String {
            switch code {
            case NX_KEYTYPE_SOUND_UP:              return "音量+"
            case NX_KEYTYPE_SOUND_DOWN:            return "音量−"
            case NX_KEYTYPE_BRIGHTNESS_UP:         return "亮度+"
            case NX_KEYTYPE_BRIGHTNESS_DOWN:       return "亮度−"
            case NX_KEYTYPE_MUTE:                  return "🔇"
            case NX_KEYTYPE_EJECT:                 return "⏏"
            case NX_KEYTYPE_PLAY:                  return "⏯"
            case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST: return "⏭"
            case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND: return "⏮"
            case NX_KEYTYPE_ILLUMINATION_UP:       return "键盘亮度+"
            case NX_KEYTYPE_ILLUMINATION_DOWN:     return "键盘亮度−"
            case NX_KEYTYPE_ILLUMINATION_TOGGLE:   return "键盘灯"
            case NX_KEYTYPE_LAUNCH_PANEL:          return "Launchpad"
            case NX_KEYTYPE_VIDMIRROR:             return "显示器镜像"
            default:                               return "功能键 \(code)"
            }
        }
    }
}

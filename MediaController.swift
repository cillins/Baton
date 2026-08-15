//
//  MediaController.swift
//  Baton
//
//  Sends system media key events (NX_SYSDEFINED subtype 8) for remote button mappings.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

class MediaController {

    func sendMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) {
        guard let nxCode = nxKeyCode(for: keyType) else { return }
        sendSystemKey(nxKeyCode: nxCode)
    }

    func sendSystemKey(nxKeyCode: Int32) {
        setSystemKey(nxKeyCode: nxKeyCode, keyDown: true)
        usleep(50000)
        setSystemKey(nxKeyCode: nxKeyCode, keyDown: false)
    }

    /// Posts one half of an NX_SYSDEFINED key transition. Push-to-talk
    /// companion mappings use this to mirror the remote's hold duration.
    func setSystemKey(nxKeyCode: Int32, keyDown: Bool) {
        let state = keyDown ? 0xa : 0xb
        let modifierRaw = keyDown ? 0xa00 : 0xb00
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierRaw)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((nxKeyCode << 16) | (Int32(state) << 8)),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cgSessionEventTap)
    }

    private func nxKeyCode(for keyType: MediaKeyInterceptor.MediaKeyType) -> Int32? {
        switch keyType {
        case .playPause: return NX_KEYTYPE_PLAY
        case .next: return NX_KEYTYPE_NEXT
        case .previous: return NX_KEYTYPE_PREVIOUS
        case .volumeUp: return NX_KEYTYPE_SOUND_UP
        case .volumeDown: return NX_KEYTYPE_SOUND_DOWN
        case .mute: return NX_KEYTYPE_MUTE
        }
    }

}

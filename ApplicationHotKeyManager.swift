//
//  ApplicationHotKeyManager.swift
//  Baton
//
//  Registers the two app-level shortcuts that must work while Baton is
//  running as an accessory app with no key window.
//

import Carbon
import Foundation

final class ApplicationHotKeyManager {
    enum Action: UInt32 {
        case toggleMainWindow = 1
        case cycleAppearance = 2
    }

    private static let signature: OSType = 0x42544E48 // "BTNH"

    private let actionHandler: (Action) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init(actionHandler: @escaping (Action) -> Void) {
        self.actionHandler = actionHandler
        install()
    }

    deinit {
        stop()
    }

    func stop() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            rmDebug("⚠️ failed to install app hot-key handler: \(handlerStatus)")
            return
        }

        register(.toggleMainWindow, keyCode: UInt32(kVK_ANSI_R))
        register(.cycleAppearance, keyCode: UInt32(kVK_ANSI_L))
    }

    private func register(_ action: Action, keyCode: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeys.append(hotKeyRef)
            rmDebug("⌨️ registered app hot key id=\(action.rawValue)")
        } else {
            rmDebug("⚠️ failed to register app hot key id=\(action.rawValue): \(status)")
        }
    }

    private static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == signature,
              let action = Action(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<ApplicationHotKeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            rmDebug("⌨️ app hot key: \(action)")
            manager.actionHandler(action)
        }
        return noErr
    }
}

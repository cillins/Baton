//
//  AppPreferences.swift
//  Baton
//
//  Persistent general-setting keys plus the narrow ServiceManagement bridge
//  used by the native settings view.
//

import Foundation
import ServiceManagement

enum AppPreferenceKey {
    static let keepRunningWhenClosed = "keepRunningWhenClosed"
    static let showBatteryInMenuBar = "showBatteryInMenuBar"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepRunningWhenClosed: true,
            showBatteryInMenuBar: false,
        ])
    }
}

enum LoginItemManager {
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static var requiresApproval: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupported
        }
        if enabled {
            if SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}

private enum LoginItemError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "登录时启动需要 macOS 13 或更高版本"
        }
    }
}

// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad support.

import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Baton", targets: ["Baton"])
    ],
    targets: [
        .executableTarget(
            name: "Baton",
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "CursorController.swift",
                "MediaController.swift",
                "MediaKeyInterceptor.swift",
                "TouchHandler.swift",
                "RemoteTouchSurface.swift",
                "SystemVolume.swift",
                "AudioProbe.swift",
                "BleAudioProbe.swift",
                "SettingsWindowController.swift",
                "SettingsUI/Theme.swift",
                "SettingsUI/RemoteArt.swift",
                "SettingsUI/SettingsViewModel.swift",
                "SettingsUI/SettingsRootView.swift",
                "SettingsUI/PermissionGuide.swift",
                "SettingsUI/Components/GroupCard.swift",
                "SettingsUI/Components/KeyValueRow.swift",
                "SettingsUI/Components/BatteryIndicator.swift",
                "SettingsUI/Components/MacSwitch.swift",
                "SettingsUI/Components/SegmentedTabs.swift",
                "SettingsUI/Components/SliderRow.swift",
                "SettingsUI/Components/KeyRecorderButton.swift",
                "SettingsUI/Components/MapRow.swift",
                "SettingsUI/Components/GroupLabel.swift",
                "SettingsUI/Components/PillButton.swift",
                "SettingsUI/Panes/SidebarView.swift",
                "SettingsUI/Panes/DetailHeaderView.swift",
                "SettingsUI/Panes/OverviewPane.swift",
                "SettingsUI/Panes/ButtonsPane.swift",
                "SettingsUI/Panes/AppsPane.swift",
                "SettingsUI/Panes/SensitivityPane.swift",
                "SettingsUI/Panes/SettingsPane.swift",
                "SettingsUI/Panes/ProfileEditSheet.swift",
                "SettingsUI/Support/RelativeTime.swift",
                "SettingsUI/Support/AppPreferences.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)

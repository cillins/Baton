//
//  SettingsRootView.swift
//  Baton
//
//  Top-level SwiftUI composition for the settings window:
//  titlebar (with traffic-light slot) -> sidebar +
//  detail body (with art panel) -> toast overlay + (when set) profile-edit modal.
//
//  The titlebar uses `ZStack` to layer a centered "Baton" title on top of
//  a right-aligned actions HStack (matches CSS .titlebar { position:
//  relative } + .wt-title { position: absolute; left: 50% }). Hosted as
//  an `NSHostingView` inside the existing `WindowContainerView` so we
//  don't touch the hand-rolled AppKit window chrome.
//

import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var vm: SettingsViewModel

    private let panes: [(Pane, String)] = [
        (.overview,    "概览"),
        (.buttons,     "按键映射"),
        (.apps,        "应用预设"),
        (.sensitivity, "灵敏度"),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // CSS .window-frame { display: flex; flex-direction: column }
            // Titlebar is a flex item (46pt), body fills the rest - NOT an
            // overlay. The sidebar starts below the titlebar, not under it.
            VStack(spacing: 0) {
                titlebar
                    .frame(height: 46)
                HStack(spacing: 0) {
                    SidebarView(vm: vm)
                    detailColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.batonSurface)
            .ignoresSafeArea()

            if let toast = vm.toast {
                VStack {
                    Spacer(minLength: 0)
                    // Keep transient feedback clear of the window edge and
                    // the lowest settings card.
                    // translateX(-50%) - horizontally centered.
                    HStack {
                        Spacer(minLength: 0)
                        ToastView(message: toast)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 64)
                }
                .transition(.opacity)
            }
        }
        .frame(width: 1020, height: 684)
        .overlay {
            if let mappings = vm.editMappings {
                ProfileEditSheet(vm: vm, mappings: mappings, onClose: { vm.closeEdit() })
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Titlebar

    private var titlebar: some View {
        ZStack {
            Color.batonSurfaceWarm
            // Centered "Baton" label — CSS .wt-title { position: absolute; left: 50%;
            // transform: translateX(-50%) }. We overlay via ZStack so the actions
            // HStack below can use margin-left: auto (right-aligned) without
            // disturbing the centered title.
            Text("Baton")
                .font(BatonFont.text(size: 13, weight: .semibold))
                .foregroundStyle(Color.batonFg2)
                .allowsHitTesting(false)
            // Right-aligned actions (margin-left: auto in CSS).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    titlebarButton("gearshape", "设置", active: vm.settingsView) {
                        vm.settingsView.toggle()
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.batonBorderSoft)
                .frame(height: 1)
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func titlebarButton(_ systemName: String,
                                _ title: String,
                                active: Bool = false,
                                action: @escaping () -> Void) -> some View {
        TitlebarButtonContent(
            systemName: systemName,
            title: title,
            active: active,
            action: action
        )
    }

    // MARK: - Detail column (body + side art panel)

    @ViewBuilder
    private var detailColumn: some View {
        HStack(spacing: 0) {
            detailBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !vm.settingsView {
                detailArtPanel
                    .frame(width: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.batonSurface)
    }

    @ViewBuilder
    private var detailBody: some View {
        // CSS .detail-body { padding: 22 26 30; overflow: auto; }
        // Children are direct children of this VStack so the ScrollView can
        // expand to fill the remaining height (a nested VStack + Spacer
        // would give the ScrollView 0 height).
        VStack(alignment: .leading, spacing: 0) {
            if vm.settingsView {
                // CSS .pane { margin-top: 16 }. SettingsPane is wrapped in
                // a ScrollView so content scrolls if it overflows (matches
                // .detail-body { overflow: auto }). .frame(maxWidth: .infinity,
                // alignment: .topLeading) forces the content to fill the
                // ScrollView's width AND align to the left edge (default
                // .center would cause the content to appear centered/narrow).
                ScrollView {
                    SettingsPane(vm: vm)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DetailHeaderView(vm: vm)
                LowBatteryAlert(vm: vm)
                // CSS .seg: margin-top 18.
                SegmentedTabs(
                    items: panes.map { $0.0 },
                    title: { pane in panes.first(where: { $0.0 == pane })?.1 ?? "" },
                    selection: $vm.selectedPane
                )
                .padding(.top, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        paneView
                    }
                    // CSS .pane { margin-top: 16 }.
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 22)   // CSS .detail-body { padding: 22 26 30 }
        .padding(.horizontal, 26)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.batonSurface)
    }

    /// Side panel showing the remote artwork. CSS .detail-art:
    /// `flex: none; width: 200px; align-self: stretch; padding: 22 22 30;
    /// display: flex; align-items: center; justify-content: center`. SVG
    /// inside fills the panel width.
    private var detailArtPanel: some View {
        ZStack {
            Color.batonSurface
            RemoteArtView(art: RemoteArtCatalog.art(for: vm.device.generation))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 22)
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var paneView: some View {
        switch vm.selectedPane {
        case .overview:    OverviewPane(vm: vm)
        case .buttons:     ButtonsPane(vm: vm, onEditProfile: handleEditProfile)
        case .apps:        AppsPane(vm: vm)
        case .sensitivity: SensitivityPane(vm: vm)
        }
    }

    // MARK: - Actions

    private func handleEditProfile(_ id: String) {
        vm.openEdit(profileId: id)
    }
}

// MARK: - Toast

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(BatonFont.text(size: 12).weight(.medium))
            .foregroundStyle(Color.batonBg)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.batonFg.opacity(0.92))
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
            .lineLimit(1)
            // CSS .toast: text-overflow: ellipsis -> truncation .tail.
            .truncationMode(.tail)
    }
}

// MARK: - Titlebar button

/// CSS .wt-btn: 28pt height, padding 0 10, 1px border-soft, radius 7, bg --bg,
/// color --fg-2, font 12. .wt-btn:hover { border-color: --meta; color: --fg }.
/// The active state follows the selected segmented-tab treatment: standard
/// foreground, raised background, soft border, and a subtle shadow.
private struct TitlebarButtonContent: View {
    let systemName: String
    let title: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .regular))
                Text(title)
                    .font(BatonFont.text(size: 12))
            }
            .foregroundStyle(active ? Color.batonFg
                          : (hovering ? Color.batonFg : Color.batonFg2))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.batonBg : Color.clear)
                    .shadow(color: active ? .black.opacity(0.12) : .clear,
                            radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(active ? Color.batonBorderSoft
                           : (hovering ? Color.batonMeta : Color.batonBorderSoft),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

//
//  SidebarView.swift
//  Baton
//
//  Left column: device picker. In native mode there's exactly one device —
//  the row is always "on", so it's effectively a status indicator for
//  connection + battery.
//
//  Matches CSS .sidebar / .sb-label / .sb-device / .sb-ricon / .sb-name /
//  .sb-status / .sb-foot / .sb-add from styles.css:304-346. The remote art
//  icon container is 16pt wide; the SVG inside is sized 12pt by the
//  canvas's intrinsic ratio — not a fixed 38×60 like the previous draft.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CSS .sb-label: font-size 11px, font-weight 700, color meta,
            // padding 4 10 6, letter-spacing 0.02em (note: SwiftUI's
            // `.tracking` is macOS 13+, so we rely on the default SF Pro Text
            // tracking at this size which matches visually).
            Text("设备")
                .font(BatonFont.text(size: 11).weight(.bold))
                .foregroundStyle(Color.batonMeta)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            deviceRow

            Spacer(minLength: 0)
        }
        // CSS .sidebar { padding: var(--space-3) var(--space-2) } = 12 8.
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 238)
        .background(Color.batonSidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.batonBorderSoft)
                .frame(width: 1)
        }
    }

    private var deviceRow: some View {
        // CSS .sb-device: display flex, align-items center, gap 10,
        // padding 8 10, radius 8. On-state: accent 13% tint + name → accent-active.
        HStack(alignment: .center, spacing: 10) {
            // CSS .sb-ricon: container 16px wide; SVG inside is 12px wide
            // (aspect-fit preserves the remote's intrinsic ratio).
            ZStack {
                RemoteArtView(art: RemoteArtCatalog.art(for: vm.device.generation))
                    .frame(width: 12)
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.device.name.isEmpty ? "Siri Remote" : vm.device.name)
                    .font(BatonFont.text(size: 13).weight(.semibold))
                    .foregroundStyle(Color.batonAccentActive)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(vm.device.connected ? "已连接 · " : "未连接 · ")
                        .font(BatonFont.text(size: 11))
                        .foregroundStyle(Color.batonMuted)
                    Text(vm.device.battery > 0 ? "\(vm.device.battery)%" : "—")
                        .font(BatonFont.text(size: 11))
                        .foregroundStyle(Color.batonMuted)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.batonAccent.opacity(0.13))
        )
    }

    private var connectionColor: Color {
        if !vm.device.connected { return Color.batonMeta }
        if vm.device.battery > 0 && vm.device.battery < 20 { return Color.batonWarn }
        return Color.batonSuccess
    }
}

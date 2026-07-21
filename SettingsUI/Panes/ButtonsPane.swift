//
//  ButtonsPane.swift
//  Baton
//
//  Mapping tab body: profile-list GroupCard. The actual button/swipe
//  editor lives in `ProfileEditSheet`. Each profile row exposes:
//   - active badge when this is the live profile (CSS .prof-active: 12/500
//     accent-active, plain text — no background pill)
//   - row actions 编辑 (查看 for `default`), 重置 (hidden for default),
//     删除 (disabled + tooltip when builtin)
//
//  Footer: 恢复默认映射 (ghost) + 新建配置… (accent primary) right-aligned
//  (CSS .map-foot: margin-top 16, justify-content flex-end, gap 8). Note
//  underneath (CSS .map-note: margin-top 14, font 12/muted).
//
//  GroupCard has padding 14/16; rows inside (CSS .prof-row) only add 11/2,
//  so rows extend close to the group edges and the map-foot / map-note
//  inherit the group's outer padding rather than adding their own.
//

import SwiftUI

struct ButtonsPane: View {
    @ObservedObject var vm: SettingsViewModel
    var onEditProfile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(headerTitle, first: true)

            GroupCard {
                VStack(spacing: 0) {
                    profileRows
                    // CSS .map-foot: margin-top 16, justify-content flex-end, gap 8.
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        PillButton(title: "恢复默认映射", variant: .ghost, action: handleResetActiveMappings)
                        PillButton(title: "新建配置…", variant: .primary, action: handleCreateProfile)
                    }
                    .padding(.top, 16)
                    // CSS .map-note: margin-top 14, font 12/muted.
                    Text("点击「编辑」在弹窗中调整按键与触控板映射。")
                        .font(BatonFont.text(size: 12))
                        .foregroundStyle(Color.batonMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                }
            }
        }
    }

    private var headerTitle: String {
        let gen = vm.device.generation == "gen1" ? "1 代" : "2/3 代"
        let name = vm.device.name.isEmpty ? "Siri Remote" : vm.device.name
        return "映射配置 · \(name)（\(gen)）"
    }

    private var profileRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.profiles.enumerated()), id: \.element.id) { idx, profile in
                if idx > 0 {
                    Rectangle()
                        .fill(Color.batonBorderSoft)
                        .frame(height: 0.5)
                        .padding(.horizontal, 2)
                }
                ProfileRow(
                    profile: profile,
                    onEdit: { onEditProfile(profile.id) },
                    onReset: { vm.resetProfile(profile.id) },
                    onDelete: { handleDelete(profile) },
                    onSelect: { vm.selectProfile(profile.id) }
                )
            }
        }
    }

    // MARK: - Actions

    private func handleResetActiveMappings() {
        guard let profile = vm.profiles.first(where: { $0.active }) else { return }
        vm.buttons.forEach { row in
            vm.setProfileMapping(profileId: profile.id, target: "button", key: row.key, actionRaw: "None")
        }
        vm.swipes.forEach { row in
            vm.setProfileMapping(profileId: profile.id, target: "swipe", key: row.key, actionRaw: "None")
        }
        vm.showToast("已恢复「\(profile.name)」的默认映射")
    }

    private func handleCreateProfile() {
        let existing = vm.profiles.map { $0.name }
        var n = 1
        while existing.contains("新配置 \(n)") { n += 1 }
        let name = "新配置 \(n)"
        guard let id = vm.createProfile(name: name) else { return }
        vm.selectProfile(id)
        vm.showToast("已创建「\(name)」")
        onEditProfile(id)
    }

    private func handleDelete(_ profile: ProfileVM) {
        if profile.builtin {
            vm.showToast("内置配置不可删除")
            return
        }
        vm.deleteProfile(profile.id)
        vm.showToast("已删除「\(profile.name)」配置")
    }
}

private struct ProfileRow: View {
    let profile: ProfileVM
    let onEdit: () -> Void
    let onReset: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        // CSS .prof-row: display flex, align-items center, gap 10,
        // padding 11 2. React ButtonsPane.jsx has no active badge and no
        // tap-to-select - the profile name is plain text.
        HStack(alignment: .center, spacing: 10) {
            Text(profile.name)
                .font(BatonFont.text(size: 13).weight(.semibold))
                .foregroundStyle(Color.batonFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // CSS .prof-row-actions: gap 2.
            HStack(spacing: 2) {
                IconActionButton(title: profile.id == "default" ? "查看" : "编辑", action: onEdit)
                if profile.id != "default" {
                    IconActionButton(title: "重置", action: onReset)
                }
                IconActionButton(
                    title: "删除",
                    tone: .danger,
                    disabled: profile.builtin,
                    tooltip: profile.builtin ? "内置配置不可删除" : nil,
                    action: profile.builtin ? {} : onDelete
                )
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
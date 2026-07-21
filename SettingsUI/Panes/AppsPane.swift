//
//  AppsPane.swift
//  Baton
//
//  App-presets tab. Lists bound apps (28×28 icon container + 24×24 icon +
//  name + 168px-wide profile picker + 移除 ghost button). Toggles an
//  inline 添加应用 list bound to the current profile.
//
//  Empty-state note + footnote + picker footer match React `AppsPane.jsx`
//  verbatim. Per CSS .app-row / .app-ic / .app-ic-img / .app-row .map-sel /
//  .app-remove / .app-add / .app-picker / .map-foot / .map-note.
//

import SwiftUI

struct AppsPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var pickerOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel("应用预设", first: true)

            GroupCard {
                VStack(spacing: 0) {
                    boundList
                    // CSS .map-note: margin-top 14, font 12/muted.
                    Text("前台打开应用时自动套用对应的配置；回到其他应用恢复当前的「默认映射」。")
                        .font(BatonFont.text(size: 12))
                        .foregroundStyle(Color.batonMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                    // CSS .map-foot: margin-top 16, justify-content flex-end.
                    HStack {
                        Spacer(minLength: 0)
                        PillButton(
                            title: pickerOpen ? "收起列表" : "添加应用…",
                            variant: .primary,
                            action: { pickerOpen.toggle() }
                        )
                    }
                    .padding(.top, 16)
                    if pickerOpen {
                        appPicker
                    }
                }
            }
        }
    }

    // MARK: - Bound apps

    @ViewBuilder
    private var boundList: some View {
        if vm.appPresets.isEmpty {
            Text("尚未绑定任何应用。下面前台打开时会套用「默认映射」。")
                .font(BatonFont.text(size: 12))
                .foregroundStyle(Color.batonMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 2)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(vm.appPresets.enumerated()), id: \.element.bundleId) { idx, preset in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.batonBorderSoft)
                            .frame(height: 0.5)
                            .padding(.horizontal, 2)
                    }
                    PresetRow(
                        preset: preset,
                        profiles: vm.profiles,
                        onChangeProfile: { newPid in
                            vm.setAppPresetProfile(bundleId: preset.bundleId, profileId: newPid)
                            let profile = vm.profiles.first { $0.id == newPid }
                            vm.showToast("「\(preset.appName)」将使用「\(profile?.name ?? "")」")
                        },
                        onRemove: {
                            vm.removeAppPreset(preset.bundleId)
                            vm.showToast("已移除「\(preset.appName)」预设")
                        }
                    )
                }
            }
        }
    }

    // MARK: - Picker (CSS .app-picker)

    private var appPicker: some View {
        // CSS .app-picker: margin-top 14, padding-top 12, border-top 1px
        // border-soft. No other padding — the rows inside still only have
        // 10/2 padding so they sit close to the parent's edges.
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.batonBorderSoft)
                .frame(height: 0.5)
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 8) {
                Text("点击应用即可绑定到当前配置「\(vm.profiles.first(where: { $0.active })?.name ?? "默认映射")」。")
                    .font(BatonFont.text(size: 12))
                    .foregroundStyle(Color.batonMuted)
                    .padding(.top, 12)
                    .padding(.horizontal, 2)
                if vm.availableApps.isEmpty {
                    Text("未发现已安装的应用。")
                        .font(BatonFont.text(size: 12))
                        .foregroundStyle(Color.batonMuted)
                        .padding(.horizontal, 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(filteredAvailable) { app in
                            AvailableAppRow(
                                app: app,
                                onAdd: {
                                    let activeId = vm.profiles.first(where: { $0.active })?.id ?? "default"
                                    let data = app.icon?.tiffRepresentation
                                    vm.addAppPreset(bundleId: app.bundleId,
                                                    appName: app.appName,
                                                    profileId: activeId,
                                                    iconData: data)
                                    vm.showToast("已将「\(app.appName)」绑定到当前配置")
                                }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var filteredAvailable: [AppVM] {
        let bound = Set(vm.appPresets.map { $0.bundleId })
        return vm.availableApps.filter { !bound.contains($0.bundleId) }
    }
}

private struct PresetRow: View {
    let preset: PresetVM
    let profiles: [ProfileVM]
    let onChangeProfile: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        // CSS .app-row: display flex, align-items center, gap 12, padding 10/2.
        HStack(alignment: .center, spacing: 12) {
            appIcon(preset.icon)
            // CSS .app-name { flex: 1; ... } - name expands to fill space.
            Text(preset.appName)
                .font(BatonFont.text(size: 13).weight(.semibold))
                .foregroundStyle(Color.batonFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            // CSS .app-row .map-sel: flex none, width 168px.
            SelectField(
                selection: preset.profileId,
                options: profiles.map { SelectFieldOption(id: $0.id, title: $0.name) },
                onSelect: onChangeProfile
            )
            .frame(width: 168)
            .frame(height: 28)
            // CSS .app-remove: .abtn.abtn-ghost.app-remove - padding 4 10,
            // margin-left 6, font 12, accent text, 1px border, transparent bg.
            Button("移除", action: onRemove)
                .buttonStyle(.plain)
                .font(BatonFont.text(size: 12).weight(.medium))
                .foregroundStyle(Color.batonAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(Color.batonBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func appIcon(_ image: NSImage?) -> some View {
        // CSS .app-ic: 28x28, radius 7, bg fg-6% tint. Image version uses
        // .app-ic-img: 24x24 inside.
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.batonFg.opacity(0.06))
                .frame(width: 28, height: 28)
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.batonFg2)
            }
        }
        .frame(width: 28, height: 28)
    }

}

private struct AvailableAppRow: View {
    let app: AppVM
    let onAdd: () -> Void

    var body: some View {
        // CSS .app-row: padding 10 2; .app-add: padding 4 14, margin-left auto.
        HStack(alignment: .center, spacing: 12) {
            appIcon(app.icon)
            // CSS .app-name { flex: 1 }.
            Text(app.appName)
                .font(BatonFont.text(size: 13).weight(.semibold))
                .foregroundStyle(Color.batonFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            // CSS .abtn (primary): padding 6 16, font 13/500, accent bg.
            // .app-add overrides padding to 4 14 + margin-left auto (push right).
            Button(action: onAdd) {
                Text("添加")
                    .font(BatonFont.text(size: 13).weight(.medium))
                    .foregroundStyle(Color.batonAccentOn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(Color.batonAccent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func appIcon(_ image: NSImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.batonFg.opacity(0.06))
                .frame(width: 28, height: 28)
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.batonFg2)
            }
        }
        .frame(width: 28, height: 28)
    }
}

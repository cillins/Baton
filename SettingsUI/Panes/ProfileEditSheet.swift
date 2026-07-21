//
//  ProfileEditSheet.swift
//  Baton
//
//  Modal sheet for editing a profile's mappings. CSS .modal-backdrop is
//  transparent (no dim) and the modal itself sits centered at width 560,
//  max-height 84vh. We host it inside a ZStack overlay in `SettingsRootView`
//  rather than as a SwiftUI `.sheet` so the visual matches (a `.sheet` would
//  attach as a system sheet with chrome we don't want).
//
//  Esc + click-outside close. The default profile (`id == "default"`) gets
//  a readOnly banner: rows are non-editable, the name field is disabled.
//
//  MapRow wiring:
//   - For "Custom Text": inline TextField → onSetCustomText(target, key, trimmed).
//   - For "Custom Key": inline KeyRecorderButton → onSetCustomKey(target, key, combo).
//

import SwiftUI
import AppKit

struct ProfileEditSheet: View {
    @ObservedObject var vm: SettingsViewModel
    var mappings: EditMappingsVM
    var onClose: () -> Void

    @State private var name: String
    @FocusState private var nameFocused: Bool

    private var isDefault: Bool { mappings.profileId == "default" }
    private var gen: String { vm.device.generation == "gen1" ? "1 代" : "2/3 代" }
    private var devName: String { vm.device.name.isEmpty ? "Siri Remote" : vm.device.name }

    init(vm: SettingsViewModel, mappings: EditMappingsVM, onClose: @escaping () -> Void) {
        self.vm = vm
        self.mappings = mappings
        self.onClose = onClose
        _name = State(initialValue: mappings.name)
    }

    var body: some View {
        ZStack {
            // Backdrop: full-window catcher that closes on click. No dim
            // (transparent). Non-default/edited-name state still gets a clean
            // close via the `onClose` callback — there's no unsaved-state
            // check; commits happen on blur/Enter.
            Color.black.opacity(0.0001)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .overlay(
                    EscapeCatcher { onClose() }
                )

            // CSS .modal: width 560 (min(560px, 92vw)), max-height 84vh.
            // We use GeometryReader to read the actual window height so 84vh
            // resolves correctly regardless of future window resizes.
            GeometryReader { geo in
                modalCard
                    .frame(width: 560)
                    .frame(maxHeight: 0.84 * geo.size.height)
                    .background(Color.batonBg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .stroke(Color.batonBorderSoft, lineWidth: 1)
                    )
                    .batonModalShadow()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .onAppear {
            // Mirror React: autofocus + select the name on non-builtin.
            if !mappings.builtin {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    nameFocused = true
                }
            }
        }
    }

    // MARK: - Card layout

    private var modalCard: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.batonBorderSoft)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isDefault {
                        defaultBanner
                    }
                    buttonsGroup
                    trackpadGroup
                }
                // CSS .modal-body { padding: 16 22 22 } - 16 top, 22 sides,
                // 22 bottom.
                .padding(.top, 16)
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if mappings.builtin {
                // A disabled TextField receives an additional platform-wide
                // opacity reduction, making built-in profile names much dimmer
                // than the CSS `opacity: 1` state. Render the read-only value
                // as text so it keeps the intended fg-2 contrast.
                Text(name)
                    .font(BatonFont.display(size: 15, weight: .semibold, tracking: -0.3))
                    .foregroundStyle(Color.batonFg2)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("配置名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(BatonFont.display(size: 15, weight: .semibold, tracking: -0.3))
                    .foregroundStyle(Color.batonFg)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(Color.batonSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .stroke(Color.batonBorder, lineWidth: 1)
                    )
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { onClose() }
                    .onChange(of: nameFocused) { focused in
                        if !focused { commitName() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onClose) {
                ModalCloseButtonContent()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s4)
        // CSS .modal-head { padding: 14 16 }.
        .padding(.vertical, 14)
    }

    private var defaultBanner: some View {
        // CSS .map-note inside modal-body: 12/muted, no extra margin when
        // first child of the column.
        Text("默认配置为系统基准，仅供查看，不可修改。")
            .font(BatonFont.text(size: 12))
            .foregroundStyle(Color.batonMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }

    private var buttonsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CSS .modal-body .group-label:first-child { margin-top: 0 }.
            // When the default banner is absent, this label is the first child.
            ModalGroupLabel("按键自定义 · \(devName)（\(gen)）", first: !isDefault)
            // CSS .modal-body .group { padding: 12 14 }.
            GroupCard(padding: 12) {
                VStack(spacing: 0) {
                    // CSS .map-head: 12/600/meta, padding 0 2 8.
                    mapHeadRow(cols: ["按键", "手势", "执行操作"])
                    ForEach(Array(mappings.buttons.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 {
                            mapRowDivider
                        }
                        mapRowBinding(row)
                    }
                }
            }
            Text("语音听写类动作需按住说话，仅适用于支持长按的按键；映射立即生效并自动保存。")
                .font(BatonFont.text(size: 12))
                .foregroundStyle(Color.batonMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        }
    }

    private var trackpadGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always second - margin-top 12.
            ModalGroupLabel("触控板手势")
            GroupCard(padding: 12) {
                VStack(spacing: 0) {
                    // Trackpad mode picker as the first row.
                    MapRow(
                        label: "触摸板模式",
                        gesture: "单指操作",
                        action: Binding(
                            get: { mappings.trackpadMode },
                            set: { newVal in
                                vm.setTrackpadMode(profileId: mappings.profileId, mode: newVal)
                            }
                        ),
                        options: [
                            ButtonOptionVM(raw: "mouse", label: "鼠标（光标控制）"),
                            ButtonOptionVM(raw: "gesture", label: "手势（滑动快捷键）"),
                        ],
                        readOnly: isDefault
                    )

                    mapHeadRow(cols: ["手势", "触发方式", "执行操作"])

                    // Swipe rows
                    ForEach(Array(mappings.swipes.enumerated()), id: \.element.id) { idx, swipe in
                        if idx > 0 {
                            mapRowDivider
                        }
                        swipeRowBinding(swipe)
                    }

                    // 滚动速度 picker
                    mapRowDivider
                    scrollSpeedRow
                }
            }
            Text("斜杠命令只会输入到输入框，需手动回车确认执行；映射立即生效并自动保存。")
                .font(BatonFont.text(size: 12))
                .foregroundStyle(Color.batonMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        }
    }

    /// CSS .map-head: grid 1.2fr 0.8fr 1fr, gap 14, padding 0 2 8,
    /// font 12/600/meta. Renders the column labels above a set of MapRows.
    private func mapHeadRow(cols: [String]) -> some View {
        MappingColumns(height: 17) {
            mapColumnTitle(cols[0])
        } second: {
            mapColumnTitle(cols[1])
        } third: {
            mapColumnTitle(cols[2])
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private func mapColumnTitle(_ title: String) -> some View {
        Text(title)
            .font(BatonFont.text(size: 12).weight(.semibold))
            .foregroundStyle(Color.batonMeta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    // MARK: - Reactive rows (local @State for editing, commit on change)

    private func mapRowBinding(_ row: ButtonRowVM) -> some View {
        // Local @State so editing the picker/key-recorder doesn't round-trip
        // through the VM for every keystroke; we push to the VM only on
        // commit.
        MapRow(
            label: row.label,
            gesture: row.gesture,
            action: Binding(
                get: { row.action },
                set: { newVal in
                    vm.setProfileMapping(profileId: mappings.profileId,
                                         target: "button",
                                         key: row.key,
                                         actionRaw: newVal)
                }
            ),
            options: row.options,
            readOnly: isDefault,
            customText: Binding(
                get: { row.customText },
                set: { newVal in
                    vm.setCustomText(target: "button", key: row.key, text: newVal.trimmingCharacters(in: .whitespaces))
                }
            ),
            customKey: Binding(
                get: { row.customKey },
                set: { _ in /* committed via onSetCustomKey */ }
            ),
            onSetCustomText: { newVal in
                vm.setCustomText(target: "button", key: row.key, text: newVal.trimmingCharacters(in: .whitespaces))
            },
            onSetCustomKey: { combo in
                vm.setCustomKey(target: "button", key: row.key, combo: combo)
            },
            onClearCustomKey: {
                vm.setCustomText(target: "button", key: row.key, text: "")
                // Easiest path: clearing a custom key means writing an empty
                // combo object — MenuBarManager interprets that as cleared.
                vm.setCustomKey(target: "button", key: row.key,
                                combo: KeyCombo(keyCode: 0, modifiers: [], label: ""))
            }
        )
    }

    private func swipeRowBinding(_ row: SwipeRowVM) -> some View {
        MapRow(
            label: row.label,
            gesture: row.desc,
            action: Binding(
                get: { row.action },
                set: { newVal in
                    vm.setProfileMapping(profileId: mappings.profileId,
                                         target: "swipe",
                                         key: row.key,
                                         actionRaw: newVal)
                }
            ),
            options: row.options,
            readOnly: isDefault,
            customText: Binding(
                get: { row.customText },
                set: { newVal in
                    vm.setCustomText(target: "swipe", key: row.key, text: newVal.trimmingCharacters(in: .whitespaces))
                }
            ),
            customKey: Binding(
                get: { row.customKey },
                set: { _ in }
            ),
            onSetCustomText: { newVal in
                vm.setCustomText(target: "swipe", key: row.key, text: newVal.trimmingCharacters(in: .whitespaces))
            },
            onSetCustomKey: { combo in
                vm.setCustomKey(target: "swipe", key: row.key, combo: combo)
            },
            onClearCustomKey: {
                vm.setCustomText(target: "swipe", key: row.key, text: "")
                vm.setCustomKey(target: "swipe", key: row.key,
                                combo: KeyCombo(keyCode: 0, modifiers: [], label: ""))
            }
        )
    }

    private var scrollSpeedRow: some View {
        // Mirrors MapRow grid: label / gesture / picker.
        MappingColumns(height: 28) {
            Text("滚动速度")
                .font(BatonFont.text(size: 13).weight(.semibold))
                .foregroundStyle(Color.batonFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        } second: {
            Text("双指滑动")
                .font(BatonFont.text(size: 12))
                .foregroundStyle(Color.batonMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        } third: {
            SelectField(
                selection: mappings.scrollSpeed,
                options: mappings.scrollSpeedOptions.map {
                    SelectFieldOption(id: $0.raw, title: $0.label)
                },
                disabled: isDefault,
                onSelect: vm.setScrollSpeed
            )
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    /// 1px soft border between adjacent `.map-row`s (CSS `.map-row + .map-row`).
    private var mapRowDivider: some View {
        Rectangle()
            .fill(Color.batonBorderSoft)
            .frame(height: 0.5)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == mappings.name || mappings.builtin { return }
        vm.renameProfile(mappings.profileId, name: trimmed)
        vm.showToast("已重命名为「\(trimmed)」")
    }

}

/// Local NSViewRepresentable that installs an app-local NSEvent monitor for Esc
/// while the modal is shown. It does **not** become first responder, so TextFields
/// inside the modal can still receive focus and keystrokes.
private struct EscapeCatcher: NSViewRepresentable {
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 /* Esc */ else { return event }
                self?.onEscape?()
                return nil
            }
        }

        func detach() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

/// CSS .modal-close: 28x28, radius 50%, bg transparent, color --muted,
/// font 18px. :hover { bg fg-8% tint, color --fg }.
private struct ModalCloseButtonContent: View {
    @State private var hovering = false

    var body: some View {
        Text("×")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(hovering ? Color.batonFg : Color.batonMuted)
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(hovering ? Color.batonFg.opacity(0.08) : Color.clear)
            )
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

import AppKit
import Carbon
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hotKeyError: String?

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("外观", systemImage: "paintbrush") }
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding(.top, 8)
        .frame(width: 520, height: 420)
        .onDisappear { stopRecording() }
    }

    private var appearanceTab: some View {
        Form {
            Section("面板布局") {
                ForEach(PanelLayout.allCases) { layout in
                    Button {
                        settings.layout = layout
                    } label: {
                        HStack(spacing: 14) {
                            layoutPreview(layout)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.title)
                                    .foregroundStyle(.primary)
                                Text(layout.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.layout == layout {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(settings.layout == layout ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: settings.layout == layout ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var generalTab: some View {
        Form {
            Section("全局唤起快捷键") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("唤起面板")
                        Text("点击右侧后按下新的组合键")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isRecording ? "按下新快捷键…" : (settings.hotKey?.displayString ?? "未设置")) {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                HStack {
                    Button("恢复默认（⌥Space）") {
                        settings.resetHotKeyToDefault()
                        hotKeyError = HotKeyManager.shared.lastErrorMessage
                        stopRecording()
                    }
                    Button("清除") {
                        settings.clearHotKey()
                        hotKeyError = nil
                        stopRecording()
                    }
                }

                if let hotKeyError {
                    Text(hotKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("首次使用全局快捷键时，系统可能要求在「隐私与安全性 → 辅助功能」中允许 FastSome。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("登录时打开 FastSome", isOn: $settings.launchAtLogin)
                Toggle("在程序坞中显示图标", isOn: $settings.showInDock)
            }

            Section("面板") {
                Toggle("打开快捷方式后关闭面板", isOn: $settings.closePanelAfterLaunch)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            Text("FastSome")
                .font(.title2.bold())
            Text("版本 1.0")
                .foregroundStyle(.secondary)
            Text("快速打开 App、文件与文件夹。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func layoutPreview(_ layout: PanelLayout) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.001))
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
            Group {
                switch layout {
                case .tabsGrid:
                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Capsule().fill(Color.white.opacity(0.55)).frame(height: 4)
                            Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                            Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                            ForEach(0..<8, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                    .frame(height: 10)
                            }
                        }
                    }
                    .padding(7)
                case .sidebar:
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.2)).frame(width: 16)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                    .frame(height: 10)
                            }
                        }
                    }
                    .padding(7)
                case .list:
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                .frame(height: 8)
                        }
                    }
                    .padding(7)
                }
            }
        }
        .frame(width: 96, height: 70)
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in stopRecording() }
                return nil
            }
            if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                return event
            }
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers(from: event.modifierFlags)
            )
            Task { @MainActor in
                if HotKeyManager.isReserved(combo) {
                    hotKeyError = "该快捷键被系统保留，请换一组。"
                    stopRecording()
                    return
                }
                settings.hotKey = combo
                settings.hotKeyEnabled = true
                // Registration happens via AppDelegate binding; surface result next runloop.
                DispatchQueue.main.async {
                    hotKeyError = HotKeyManager.shared.lastErrorMessage
                }
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

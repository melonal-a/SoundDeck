import AppKit
import CoreAudio
import SwiftUI

struct SoundPanelView: View {
    @ObservedObject var audio: AudioManager
    @ObservedObject var microphone: MicrophoneMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            volumeControl
                .padding(.top, 12)
            outputSection
                .padding(.top, 16)
            inputSection
                .padding(.top, 16)
            if let error = audio.errorMessage {
                errorBanner(error)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 356, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: audio.errorMessage)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("声音")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(audio.outputDeviceName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    openSoundSettings()
                } label: {
                    Label("打开系统声音设置", systemImage: "gearshape")
                }

                Button {
                    audio.refresh()
                } label: {
                    Label("重新扫描音频设备", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    showAboutPanel()
                } label: {
                    Label("关于 SoundDeck \(appVersion)", systemImage: "info.circle")
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出 SoundDeck", systemImage: "power")
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多操作")
        }
    }

    // MARK: - Output volume

    private var volumeControl: some View {
        HStack(spacing: 11) {
            Button {
                audio.toggleOutputMute()
            } label: {
                Image(systemName: audio.speakerSymbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(audio.hasOutputMute ? Color.primary : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!audio.hasOutputMute)
            .opacity(audio.hasOutputMute ? 1 : 0.55)
            .help(audio.isOutputMuted ? "取消静音" : "静音")
            .accessibilityLabel(audio.isOutputMuted ? "取消静音" : "静音")

            Slider(
                value: Binding(
                    get: { audio.outputVolume },
                    set: { audio.setOutputVolume($0) }
                ),
                in: 0...1,
                onEditingChanged: { audio.setOutputVolumeEditing($0) }
            )
            .controlSize(.small)
            .disabled(!audio.hasOutputVolume)
            .opacity(audio.hasOutputVolume ? 1 : 0.5)
            .accessibilityLabel("输出音量")
            .accessibilityValue(percentText(audio.outputVolume, available: audio.hasOutputVolume))

            Text(percentText(audio.outputVolume, available: audio.hasOutputVolume))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .help(audio.hasOutputVolume ? "调整输出音量" : "当前输出设备不支持系统音量调节")
    }

    // MARK: - Output devices

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("输出设备", count: audio.outputDevices.count, maxVisible: 4)

            VStack(spacing: 0) {
                if audio.outputDevices.isEmpty {
                    emptyRow("没有可用的输出设备", symbol: "speaker.slash")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 2) {
                                ForEach(audio.outputDevices) { device in
                                    DeviceRow(
                                        device: device,
                                        direction: .output,
                                        isSelected: device.id == audio.defaultOutputID
                                    ) {
                                        audio.selectOutputDevice(device)
                                    }
                                    .id(device.id)
                                }
                            }
                        }
                        .frame(height: listHeight(count: audio.outputDevices.count, maxVisible: 4))
                        .scrollIndicators(.never)
                        .scrollBounceBehavior(.basedOnSize)
                        .onAppear {
                            scroll(proxy, to: audio.defaultOutputID, animated: false)
                        }
                        .onChange(of: audio.defaultOutputID) { _, newValue in
                            scroll(proxy, to: newValue, animated: true)
                        }
                        .onChange(of: audio.outputDevices) { _, _ in
                            scroll(proxy, to: audio.defaultOutputID, animated: false)
                        }
                    }
                }
            }
            .padding(4)
            .background(cardBackground)
        }
    }

    // MARK: - Input devices and volume

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("输入设备", count: audio.inputDevices.count, maxVisible: 4)

            VStack(spacing: 0) {
                if audio.inputDevices.isEmpty {
                    emptyRow("没有可用的输入设备", symbol: "mic.slash")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 2) {
                                ForEach(audio.inputDevices) { device in
                                    let isSelected = device.id == audio.defaultInputID
                                    DeviceRow(
                                        device: device,
                                        direction: .input,
                                        isSelected: isSelected,
                                        waveform: isSelected
                                            ? MicrophoneWaveformView(microphone: microphone)
                                            : nil
                                    ) {
                                        audio.selectInputDevice(device)
                                    }
                                    .id(device.id)
                                }
                            }
                        }
                        .frame(height: listHeight(count: audio.inputDevices.count, maxVisible: 4))
                        .scrollIndicators(.never)
                        .scrollBounceBehavior(.basedOnSize)
                        .onAppear {
                            scroll(proxy, to: audio.defaultInputID, animated: false)
                        }
                        .onChange(of: audio.defaultInputID) { _, newValue in
                            scroll(proxy, to: newValue, animated: true)
                        }
                        .onChange(of: audio.inputDevices) { _, _ in
                            scroll(proxy, to: audio.defaultInputID, animated: false)
                        }
                    }
                }

                Divider()
                    .overlay(Color.primary.opacity(0.07))
                    .padding(.horizontal, 7)

                HStack(spacing: 9) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text("输入音量")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Slider(
                        value: Binding(
                            get: { audio.inputVolume },
                            set: { audio.setInputVolume($0) }
                        ),
                        in: 0...1,
                        onEditingChanged: { audio.setInputVolumeEditing($0) }
                    )
                    .controlSize(.small)
                    .disabled(!audio.hasInputVolume)
                    .opacity(audio.hasInputVolume ? 1 : 0.5)
                    .accessibilityLabel("输入音量")
                    .accessibilityValue(percentText(audio.inputVolume, available: audio.hasInputVolume))

                    Text(percentText(audio.inputVolume, available: audio.hasInputVolume))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .help(audio.hasInputVolume ? "调整输入音量" : "当前输入设备不支持系统音量调节")

                if microphone.permissionState == .denied {
                    Divider()
                        .overlay(Color.primary.opacity(0.07))
                        .padding(.horizontal, 7)

                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)

                        Text("允许麦克风访问后显示实时波形")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Button("打开设置") {
                            microphone.openPrivacySettings()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("打开麦克风隐私设置")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                }
            }
            .background(cardBackground)
        }
    }

    // MARK: - Reusable pieces

    private func sectionHeader(_ title: String, count: Int, maxVisible: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if count > maxVisible {
                Text("可滚动")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("\(count) 个")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(count) 个可用设备")
    }

    private func emptyRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 7)
        .frame(height: 40)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                audio.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.11))
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
            )
    }

    private func listHeight(count: Int, maxVisible: Int) -> CGFloat {
        let visible = min(count, maxVisible)
        guard visible > 0 else { return 0 }
        return CGFloat(visible) * 40 + CGFloat(visible - 1) * 2
    }

    private func percentText(_ value: Double, available: Bool) -> String {
        guard available else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func scroll(_ proxy: ScrollViewProxy, to deviceID: AudioDeviceID?, animated: Bool) {
        guard let deviceID else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(deviceID, anchor: .center)
                }
            } else {
                proxy.scrollTo(deviceID, anchor: .center)
            }
        }
    }

    private func openSoundSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func showAboutPanel() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: AudioDevice
    let direction: AudioDirection
    let isSelected: Bool
    let waveform: MicrophoneWaveformView?
    let action: () -> Void

    @State private var isHovered = false

    init(
        device: AudioDevice,
        direction: AudioDirection,
        isSelected: Bool,
        waveform: MicrophoneWaveformView? = nil,
        action: @escaping () -> Void
    ) {
        self.device = device
        self.direction = direction
        self.isSelected = isSelected
        self.waveform = waveform
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    Image(systemName: device.symbolName(for: direction))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(device.transportLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    if let waveform {
                        waveform
                            .frame(width: 48, height: 18)
                            .padding(.leading, 2)
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help("设为默认\(direction == .output ? "输出" : "输入")设备：\(device.name)")
        .accessibilityLabel("\(device.name)，\(device.transportLabel)")
        .accessibilityValue(isSelected ? "当前默认\(direction == .output ? "输出" : "输入")设备" : "")
        .accessibilityHint("设为默认\(direction == .output ? "输出" : "输入")设备")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(isHovered ? 0.17 : 0.11)
        }
        return isHovered ? Color.primary.opacity(0.055) : Color.clear
    }
}

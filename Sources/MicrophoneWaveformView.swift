import SwiftUI

/// Small live waveform shown inside the selected input-device row.
struct MicrophoneWaveformView: View {
    @ObservedObject var microphone: MicrophoneMonitor

    var body: some View {
        Group {
            if microphone.permissionState == .denied {
                statusIcon("mic.slash", color: .secondary)
                    .help("麦克风权限未开启，无法显示实时波形")
            } else {
                switch microphone.captureState {
                case .capturing:
                    LiveWaveform(levels: microphone.levels)
                        .help("实时麦克风波形（仅面板打开时采集）")
                case .starting:
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .help("正在连接麦克风…")
                case .failed:
                    statusIcon("exclamationmark.triangle.fill", color: .orange)
                        .help("麦克风波形启动失败")
                case .idle:
                    baseline
                        .help("打开面板后开始显示实时麦克风波形")
                }
            }
        }
        .frame(width: 48, height: 18)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func statusIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var baseline: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.24))
            .frame(height: 1)
            .padding(.horizontal, 3)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Canvas

private struct LiveWaveform: View {
    let levels: [CGFloat]

    private let barCount = 18

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let maxHeight = max(2, size.height - 3)
            let width = size.width
            let values = downsampledLevels()
            let barWidth: CGFloat = 1.55
            let gap = max(0.8, (width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))

            var baseline = Path()
            baseline.move(to: CGPoint(x: 1, y: midY))
            baseline.addLine(to: CGPoint(x: width - 1, y: midY))
            context.stroke(
                baseline,
                with: .color(Color.secondary.opacity(0.20)),
                style: StrokeStyle(lineWidth: 0.75, lineCap: .round)
            )

            let hasSignal = values.contains { $0 > 0.015 }
            let accent = Color.accentColor

            for index in 0..<barCount {
                let level = max(values[index], hasSignal ? 0.055 : 0)
                let height = max(1.2, min(1, level) * maxHeight)
                let x = CGFloat(index) * (barWidth + gap) + (width - (CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap)) / 2
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                // Soft outer glow, then the bright center line of the bar.
                let glowRect = rect.insetBy(dx: -0.65, dy: -0.4)
                context.fill(
                    Path(roundedRect: glowRect, cornerRadius: barWidth / 2 + 0.65),
                    with: .color(accent.opacity(0.13))
                )
                context.fill(
                    bar,
                    with: .linearGradient(
                        Gradient(colors: [
                            accent.opacity(0.98),
                            accent.opacity(0.64)
                        ]),
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)
                    )
                )
            }
        }
    }

    private func downsampledLevels() -> [CGFloat] {
        let count = barCount
        let values = levels.isEmpty ? [CGFloat](repeating: 0, count: count) : levels
        guard values.count != count else { return values }

        return (0..<count).map { index in
            let start = index * values.count / count
            let end = max(start + 1, (index + 1) * values.count / count)
            return values[start..<min(end, values.count)].max() ?? 0
        }
    }
}

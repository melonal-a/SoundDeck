import AppKit
import AVFoundation
import Combine
import Foundation
import os

/// Captures the default microphone only while the menu panel is visible.
///
/// The engine is created on `startSession()` and torn down on `stopSession()`.
/// Audio samples never leave this process and are reduced to a small set of
/// display levels for the waveform.
final class MicrophoneMonitor: ObservableObject {
    enum PermissionState: Equatable {
        case unknown
        case requesting
        case authorized
        case denied
    }

    enum CaptureState: Equatable {
        case idle
        case starting
        case capturing
        case failed(String)
    }

    static let levelCount = 32

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: levelCount)

    private let logger = Logger(subsystem: "local.sounddeck.app", category: "microphone")
    private let stateQueue = DispatchQueue.main

    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false
    private var permissionRequestInFlight = false
    private var generation: UInt64 = 0
    private var restartWorkItem: DispatchWorkItem?

    private var lastPublishTime: CFTimeInterval = 0

    var isCapturing: Bool {
        if case .capturing = captureState { return true }
        return false
    }

    var needsPermission: Bool {
        permissionState == .denied
    }

    // MARK: - Session lifecycle

    func startSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !sessionActive else { return }

        sessionActive = true
        logger.debug("Microphone session requested")
        refreshPermissionAndStartIfPossible()
    }

    func stopSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sessionActive || engine != nil else { return }

        sessionActive = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        generation &+= 1

        teardownEngine()
        clearWaveform()
        captureState = .idle
        logger.debug("Microphone session stopped; capture is off")
    }

    func restartForInputDeviceChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sessionActive else { return }

        restartWorkItem?.cancel()
        restartWorkItem = nil
        generation &+= 1
        teardownEngine()
        clearWaveform()

        guard permissionState == .authorized else {
            refreshPermissionAndStartIfPossible()
            return
        }

        captureState = .starting
        logger.debug("Input device changed; restarting microphone capture")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.sessionActive else { return }
            self.restartWorkItem = nil
            self.startCapture()
        }
        restartWorkItem = workItem
        // Give CoreAudio a moment to finish moving the default input.
        stateQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Permission

    private func refreshPermissionAndStartIfPossible() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            permissionState = .authorized
            startCapture()

        case .notDetermined:
            permissionState = .requesting
            requestMicrophonePermission()

        case .denied, .restricted:
            permissionState = .denied
            teardownEngine()
            captureState = .idle
            clearWaveform()

        @unknown default:
            permissionState = .denied
            teardownEngine()
            captureState = .idle
            clearWaveform()
        }
    }

    private func requestMicrophonePermission() {
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionRequestInFlight = false
                self.permissionState = granted ? .authorized : .denied
                self.logger.debug("Microphone permission \(granted ? "granted" : "denied", privacy: .public)")

                guard self.sessionActive else {
                    // The panel was closed while the system sheet was visible.
                    // Never start capturing after the interface has gone away.
                    self.captureState = .idle
                    return
                }

                if granted {
                    self.startCapture()
                } else {
                    self.teardownEngine()
                    self.captureState = .idle
                    self.clearWaveform()
                }
            }
        }
    }

    // MARK: - Capture

    private func startCapture() {
        guard sessionActive else { return }
        guard permissionState == .authorized else { return }

        restartWorkItem?.cancel()
        restartWorkItem = nil
        generation &+= 1
        let captureGeneration = generation

        teardownEngine()
        captureState = .starting

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        guard format.channelCount > 0, format.sampleRate > 0 else {
            let message = "没有检测到可用的麦克风输入"
            captureState = .failed(message)
            logger.error("Cannot start microphone capture: input format is unavailable")
            return
        }

        engine = newEngine
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, generation: captureGeneration)
        }
        tapInstalled = true

        newEngine.prepare()
        do {
            try newEngine.start()
            guard sessionActive, generation == captureGeneration else {
                teardownEngine()
                return
            }
            captureState = .capturing
            logger.debug("Microphone capture started")
        } catch {
            logger.error("Unable to start microphone engine: \(error.localizedDescription, privacy: .public)")
            teardownEngine()
            captureState = .failed("无法启动麦克风：\(error.localizedDescription)")
            clearWaveform()
        }
    }

    private func teardownEngine() {
        guard let engine else { return }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        self.engine = nil
    }

    private func clearWaveform() {
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    // MARK: - Sample processing

    private func consume(buffer: AVAudioPCMBuffer, generation captureGeneration: UInt64) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        let binCount = Self.levelCount
        var peaks = [Float](repeating: 0, count: binCount)
        let samplesPerBin = max(1, frameCount / binCount)

        for bin in 0..<binCount {
            let start = bin * samplesPerBin
            guard start < frameCount else { break }
            let end = min(start + samplesPerBin, frameCount)
            var binPeak: Float = 0

            for channel in 0..<channelCount {
                let samples = channelData[channel]
                var index = start
                while index < end {
                    let magnitude = abs(samples[index])
                    if magnitude > binPeak { binPeak = magnitude }
                    index += 1
                }
            }

            peaks[bin] = binPeak
        }

        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= (1.0 / 30.0) else { return }
        lastPublishTime = now

        let displayValues = peaks.map(Self.displayLevel(for:))
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.sessionActive,
                  self.generation == captureGeneration,
                  self.isCapturing else { return }
            self.publish(displayValues)
        }
    }

    private func publish(_ rawLevels: [Float]) {
        var nextLevels = [CGFloat](repeating: 0, count: Self.levelCount)
        for index in 0..<Self.levelCount {
            let incoming = CGFloat(rawLevels[index])
            let previous = levels[index] * 0.72
            nextLevels[index] = max(incoming, previous)
        }
        levels = nextLevels
    }

    private static func displayLevel(for peak: Float) -> Float {
        // Ignore the noise floor of most built-in microphones, then use a square-root
        // curve so quiet speech still produces a visible, natural-looking waveform.
        guard peak > 0.0015 else { return 0 }
        let normalized = min(1, (peak - 0.0015) * 7.0)
        return sqrt(normalized)
    }
}

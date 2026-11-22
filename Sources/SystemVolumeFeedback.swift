import AppKit
import Foundation
import os

/// Plays macOS's own volume-change feedback sound.
///
/// No audio is bundled with SoundDeck. The exact file used by macOS for
/// "Play feedback when volume is changed" is loaded from the system, and the
/// system preference is honored. The click is intentionally not synthesized
/// or replaced by a custom asset.
final class SystemVolumeFeedback {
    enum Channel {
        case output
        case input
    }

    private let logger = Logger(subsystem: "local.sounddeck.app", category: "volume-feedback")
    private let feedbackPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    private let stepCount = 16
    private let minimumInterval: TimeInterval = 0.07

    private var sound: NSSound?
    private var didAttemptLoad = false
    private var lastStepByChannel: [Channel: Int] = [:]
    private var lastPlaybackTime: TimeInterval = 0

    /// Called when a new slider gesture begins so the first movement always
    /// gives feedback, even if it stays within the previous 1/16 step.
    func editingBegan(for channel: Channel) {
        lastStepByChannel[channel] = nil
    }

    /// Called when the user changes an in-app volume slider.
    func volumeChanged(to level: Double, channel: Channel) {
        let clamped = min(max(level, 0), 1)
        let step = Int((clamped * Double(stepCount)).rounded())

        if let previousStep = lastStepByChannel[channel], previousStep == step {
            return
        }
        lastStepByChannel[channel] = step

        // A full-range drag can produce many updates. The click is only a few
        // dozen milliseconds long, so a small guard interval prevents a burst
        // of overlapping feedback while still feeling immediate.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlaybackTime >= minimumInterval else { return }

        guard systemFeedbackEnabled else { return }
        guard let sound = loadedSound else { return }

        lastPlaybackTime = now
        if sound.isPlaying {
            sound.stop()
        }
        if sound.play() {
            logger.debug("Played system volume feedback")
        } else {
            logger.debug("System volume feedback did not start")
        }
    }

    // MARK: - System resources

    private var loadedSound: NSSound? {
        if didAttemptLoad {
            return sound
        }

        didAttemptLoad = true
        guard FileManager.default.fileExists(atPath: feedbackPath) else {
            logger.debug("System volume feedback file is unavailable")
            return nil
        }

        let loaded = NSSound(contentsOfFile: feedbackPath, byReference: true)
        loaded?.volume = 1.0
        sound = loaded
        return loaded
    }

    /// The same global preference used by the macOS Sound settings panel:
    /// "Play feedback when volume is changed".
    private var systemFeedbackEnabled: Bool {
        let key = "com.apple.sound.beep.feedback" as CFString
        guard let value = CFPreferencesCopyValue(
            key,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber else {
            return true
        }
        return value.boolValue
    }
}

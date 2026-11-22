import AppKit
import SwiftUI

@main
struct SoundDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio: AudioManager
    @StateObject private var microphone: MicrophoneMonitor

    init() {
        let manager = AudioManager()
        manager.start()
        _audio = StateObject(wrappedValue: manager)
        _microphone = StateObject(wrappedValue: MicrophoneMonitor())
    }

    var body: some Scene {
        MenuBarExtra {
            SoundPanelView(audio: audio, microphone: microphone)
                // Microphone capture is deliberately bound to the lifetime of the
                // popover. When the panel disappears, the engine and its tap are torn
                // down immediately, so nothing is captured in the background.
                .onAppear {
                    microphone.startSession()
                }
                .onDisappear {
                    microphone.stopSession()
                }
                .onChange(of: audio.defaultInputID) { _, _ in
                    microphone.restartForInputDeviceChange()
                }
        } label: {
            Image(systemName: audio.statusSymbolName)
                .accessibilityLabel("SoundDeck 声音控制")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

import CoreAudio
import Foundation

/// A snapshot of an audio device that can be shown in the menu.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let inputChannels: Int
    let outputChannels: Int

    var canOutput: Bool { outputChannels > 0 }
    var canInput: Bool { inputChannels > 0 }

    var transportLabel: String {
        if name.localizedLowercase.contains("iphone") {
            return "连续互通"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "内置"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "蓝牙"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:
            return "显示器"
        case kAudioDeviceTransportTypeAirPlay:
            return "AirPlay"
        case kAudioDeviceTransportTypeVirtual:
            return "虚拟"
        case kAudioDeviceTransportTypeAggregate:
            return "聚合"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeThunderbolt:
            return "雷雳"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case UInt32(0x6363_7764): // 'ccwd' — Continuity / iPhone microphone
            return "连续互通"
        default:
            return "音频设备"
        }
    }

    func symbolName(for direction: AudioDirection) -> String {
        let lowercaseName = name.localizedLowercase

        if lowercaseName.contains("airpods") || lowercaseName.contains("beats") {
            return "airpodspro"
        }
        if lowercaseName.contains("iphone") {
            return "iphone"
        }

        switch direction {
        case .output:
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                return "hifispeaker.fill"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return "headphones"
            case kAudioDeviceTransportTypeUSB:
                return lowercaseName.contains("headphone") || lowercaseName.contains("headset")
                    ? "headphones"
                    : "slider.horizontal.3"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
                return "display"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeVirtual, UInt32(0x6363_7764):
                return "waveform"
            case kAudioDeviceTransportTypeAggregate:
                return "square.stack.3d.up"
            default:
                return "speaker.wave.2.fill"
            }

        case .input:
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                return "mic.fill"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return "headset"
            case kAudioDeviceTransportTypeUSB:
                return "mic.fill"
            case UInt32(0x6363_7764):
                return "iphone"
            case kAudioDeviceTransportTypeVirtual:
                return "waveform"
            case kAudioDeviceTransportTypeAggregate:
                return "square.stack.3d.up"
            default:
                return "mic.fill"
            }
        }
    }

    /// A stable order: built-in first, then personal/portable devices, then external displays and virtual devices.
    var sortRank: Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return 0
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return 1
        case kAudioDeviceTransportTypeUSB:
            return 2
        case UInt32(0x6363_7764):
            return 3
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return 4
        case kAudioDeviceTransportTypeAirPlay:
            return 5
        case kAudioDeviceTransportTypeVirtual:
            return 6
        case kAudioDeviceTransportTypeAggregate:
            return 7
        default:
            return 8
        }
    }
}

enum AudioDirection {
    case output
    case input
}

import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Owns all CoreAudio state for the menu. Every mutation and published update happens on the main thread.
final class AudioManager: ObservableObject {
    // MARK: - Published state

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []

    @Published private(set) var defaultOutputID: AudioDeviceID?
    @Published private(set) var defaultInputID: AudioDeviceID?

    @Published private(set) var outputDeviceName = "未选择输出设备"
    @Published private(set) var inputDeviceName = "未选择输入设备"

    @Published private(set) var outputVolume: Double = 0
    @Published private(set) var inputVolume: Double = 0

    @Published private(set) var hasOutputVolume = false
    @Published private(set) var hasInputVolume = false
    @Published private(set) var hasOutputMute = false
    @Published private(set) var isOutputMuted = false

    @Published private(set) var errorMessage: String?

    // MARK: - CoreAudio objects

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue.main
    private var hasStarted = false
    private let volumeFeedback = SystemVolumeFeedback()

    private struct PropertyListener {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct ListenerDescriptor: Equatable {
        let objectID: AudioDeviceID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement
    }

    private struct VolumeControl {
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let elements: [AudioObjectPropertyElement]
    }

    private struct MuteControl {
        let scope: AudioObjectPropertyScope
        let elements: [AudioObjectPropertyElement]
    }

    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var activeDeviceDescriptors: [ListenerDescriptor] = []

    private var outputVolumeControl: VolumeControl?
    private var outputMuteControl: MuteControl?
    private var inputVolumeControl: VolumeControl?

    private var deviceNameCache: [AudioDeviceID: String] = [:]

    private var refreshTimer: Timer?
    private var timerTick = 0

    private var fullRefreshGeneration = 0
    private var levelRefreshGeneration = 0
    private var errorDismissGeneration = 0

    private var isEditingOutputVolume = false
    private var isEditingInputVolume = false

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        installSystemListeners()
        refreshAll()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.timerFired()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        refreshTimer?.invalidate()
        removeListeners(systemListeners)
        removeListeners(deviceListeners)
    }

    // MARK: - Public API

    /// Rebuilds the device list, re-reads the system defaults, and refreshes all controls.
    func refresh() {
        refreshAll()
    }

    func selectOutputDevice(_ device: AudioDevice) {
        guard device.canOutput else { return }
        guard device.id != defaultOutputID else { return }

        let status = setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard status == noErr else {
            reportError("无法切换到「\(device.name)」（错误 \(status)）")
            return
        }

        // macOS keeps a separate system-sound output. Mirroring the native Sound panel keeps
        // alerts and UI sounds on the same device.
        _ = setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)

        defaultOutputID = device.id
        outputDeviceName = device.name
        scheduleFullRefresh()
    }

    func selectInputDevice(_ device: AudioDevice) {
        guard device.canInput else { return }
        guard device.id != defaultInputID else { return }

        let status = setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
        guard status == noErr else {
            reportError("无法切换到「\(device.name)」（错误 \(status)）")
            return
        }

        defaultInputID = device.id
        inputDeviceName = device.name
        scheduleFullRefresh()
    }

    func setOutputVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        update(\.outputVolume, clamped)

        guard let deviceID = defaultOutputID, let control = outputVolumeControl else { return }

        if isOutputMuted, hasOutputMute, let muteControl = outputMuteControl {
            if setMute(false, deviceID: deviceID, control: muteControl) {
                isOutputMuted = false
            }
        }

        if setVolume(clamped, deviceID: deviceID, control: control) {
            volumeFeedback.volumeChanged(to: clamped, channel: .output)
        }
    }

    func setInputVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        update(\.inputVolume, clamped)

        guard let deviceID = defaultInputID, let control = inputVolumeControl else { return }
        if setVolume(clamped, deviceID: deviceID, control: control) {
            volumeFeedback.volumeChanged(to: clamped, channel: .input)
        }
    }

    func setOutputVolumeEditing(_ editing: Bool) {
        isEditingOutputVolume = editing
        if editing {
            volumeFeedback.editingBegan(for: .output)
        } else {
            scheduleLevelRefresh()
        }
    }

    func setInputVolumeEditing(_ editing: Bool) {
        isEditingInputVolume = editing
        if editing {
            volumeFeedback.editingBegan(for: .input)
        } else {
            scheduleLevelRefresh()
        }
    }

    func toggleOutputMute() {
        guard let deviceID = defaultOutputID, let control = outputMuteControl else { return }

        let target = !isOutputMuted
        if setMute(target, deviceID: deviceID, control: control) {
            isOutputMuted = target
        } else {
            reportError("无法更改输出静音状态")
            scheduleLevelRefresh()
        }
    }

    func dismissError() {
        errorMessage = nil
        errorDismissGeneration += 1
    }

    // Property names consumed by the view.

    var statusSymbolName: String {
        if defaultOutputID == nil || isOutputMuted {
            return "speaker.slash.fill"
        }
        guard hasOutputVolume else {
            return "speaker.wave.2.fill"
        }
        switch outputVolume {
        case ...0.001:
            return "speaker.fill"
        case ..<0.34:
            return "speaker.wave.1.fill"
        case ..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    var speakerSymbolName: String {
        if isOutputMuted { return "speaker.slash.fill" }
        switch outputVolume {
        case ...0.001:
            return "speaker.fill"
        case ..<0.34:
            return "speaker.wave.1.fill"
        case ..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    // MARK: - Device enumeration

    private func refreshAll() {
        let devices = loadDevices()
        let outputs = devices.filter(\.canOutput).sorted(by: deviceSort)
        let inputs = devices.filter(\.canInput).sorted(by: deviceSort)

        update(\.outputDevices, outputs)
        update(\.inputDevices, inputs)

        let defaultOutput = readUInt32(systemObjectID, address(kAudioHardwarePropertyDefaultOutputDevice))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
        let defaultInput = readUInt32(systemObjectID, address(kAudioHardwarePropertyDefaultInputDevice))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }

        update(\.defaultOutputID, defaultOutput)
        update(\.defaultInputID, defaultInput)

        let outputName = outputs.first(where: { $0.id == defaultOutput })?.name ?? "未选择输出设备"
        let inputName = inputs.first(where: { $0.id == defaultInput })?.name ?? "未选择输入设备"
        update(\.outputDeviceName, outputName)
        update(\.inputDeviceName, inputName)

        if let defaultOutput {
            outputVolumeControl = volumeControl(for: defaultOutput, scope: kAudioObjectPropertyScopeOutput)
            outputMuteControl = muteControl(for: defaultOutput, scope: kAudioObjectPropertyScopeOutput)
        } else {
            outputVolumeControl = nil
            outputMuteControl = nil
        }

        if let defaultInput {
            inputVolumeControl = volumeControl(for: defaultInput, scope: kAudioObjectPropertyScopeInput)
        } else {
            inputVolumeControl = nil
        }

        refreshLevels()
        syncDeviceListeners()
    }

    private func loadDevices() -> [AudioDevice] {
        let ids = readDeviceIDs()
        var result: [AudioDevice] = []

        for id in ids where id != kAudioObjectUnknown {
            let outputChannels = channelCount(objectID: id, scope: kAudioObjectPropertyScopeOutput)
            let inputChannels = channelCount(objectID: id, scope: kAudioObjectPropertyScopeInput)
            guard outputChannels > 0 || inputChannels > 0 else { continue }

            let transport = readUInt32(id, address(kAudioDevicePropertyTransportType)) ?? 0
            let name = deviceName(for: id)

            // AVAudioEngine creates a private aggregate device when it starts
            // capturing. It is an implementation detail, not a user-facing input,
            // and listing it would make the device list jump while the panel is open.
            guard !name.hasPrefix("CADefaultDeviceAggregate-") else { continue }

            result.append(AudioDevice(
                id: id,
                name: name,
                transport: transport,
                inputChannels: inputChannels,
                outputChannels: outputChannels
            ))
        }

        return result
    }

    private func deviceName(for id: AudioDeviceID) -> String {
        if let cached = deviceNameCache[id] {
            return cached
        }

        if let name = readString(id, address(kAudioObjectPropertyName)), !name.isEmpty {
            deviceNameCache[id] = name
            return name
        }

        return "未命名音频设备"
    }

    private func deviceSort(_ lhs: AudioDevice, _ rhs: AudioDevice) -> Bool {
        if lhs.sortRank != rhs.sortRank {
            return lhs.sortRank < rhs.sortRank
        }
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return lhs.id < rhs.id
        }
    }

    private func readDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &propertyAddress, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObjectID,
            &propertyAddress,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids
    }

    private func channelCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size) == noErr,
              size > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, rawPointer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Level refreshes

    private func refreshLevels() {
        refreshOutputLevels()
        refreshInputLevels()
    }

    private func refreshOutputLevels() {
        guard let deviceID = defaultOutputID else {
            update(\.hasOutputVolume, false)
            update(\.hasOutputMute, false)
            update(\.isOutputMuted, false)
            update(\.outputVolume, 0)
            return
        }

        if !isEditingOutputVolume {
            if let control = outputVolumeControl,
               let level = readVolume(deviceID: deviceID, control: control) {
                update(\.hasOutputVolume, true)
                update(\.outputVolume, roundedLevel(level))
            } else {
                update(\.hasOutputVolume, false)
                update(\.outputVolume, 0)
            }
        }

        if let control = outputMuteControl,
           let muted = readMute(deviceID: deviceID, control: control) {
            update(\.hasOutputMute, true)
            update(\.isOutputMuted, muted)
        } else {
            update(\.hasOutputMute, false)
            update(\.isOutputMuted, false)
        }
    }

    private func refreshInputLevels() {
        guard let deviceID = defaultInputID else {
            update(\.hasInputVolume, false)
            update(\.inputVolume, 0)
            return
        }

        guard !isEditingInputVolume else { return }

        if let control = inputVolumeControl,
           let level = readVolume(deviceID: deviceID, control: control) {
            update(\.hasInputVolume, true)
            update(\.inputVolume, roundedLevel(level))
        } else {
            update(\.hasInputVolume, false)
            update(\.inputVolume, 0)
        }
    }

    private func roundedLevel(_ level: Double) -> Double {
        (level * 1000).rounded() / 1000
    }

    // MARK: - Volume and mute primitives

    private func volumeControl(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> VolumeControl? {
        // Master volume is what the macOS Sound panel uses when a device exposes it.
        let mainAddress = address(
            kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if isSettable(deviceID, mainAddress) {
            return VolumeControl(
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope,
                elements: [kAudioObjectPropertyElementMain]
            )
        }

        // Some drivers only publish the hardware-service virtual main volume.
        let virtualAddress = address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if isSettable(deviceID, virtualAddress) {
            return VolumeControl(
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: scope,
                elements: [kAudioObjectPropertyElementMain]
            )
        }

        // Fall back to per-channel controls for devices without a master element.
        let channels = channelCount(objectID: deviceID, scope: scope)
        guard channels > 0 else { return nil }

        let elements = (1...AudioObjectPropertyElement(min(channels, 32))).compactMap { channel -> AudioObjectPropertyElement? in
            let channelAddress = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: channel)
            return isSettable(deviceID, channelAddress) ? channel : nil
        }

        guard !elements.isEmpty else { return nil }
        return VolumeControl(
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            elements: elements
        )
    }

    private func muteControl(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> MuteControl? {
        let mainAddress = address(
            kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if isSettable(deviceID, mainAddress) {
            return MuteControl(scope: scope, elements: [kAudioObjectPropertyElementMain])
        }

        let channels = channelCount(objectID: deviceID, scope: scope)
        guard channels > 0 else { return nil }

        let elements = (1...AudioObjectPropertyElement(min(channels, 32))).compactMap { channel -> AudioObjectPropertyElement? in
            let channelAddress = address(kAudioDevicePropertyMute, scope: scope, element: channel)
            return isSettable(deviceID, channelAddress) ? channel : nil
        }

        guard !elements.isEmpty else { return nil }
        return MuteControl(scope: scope, elements: elements)
    }

    private func readVolume(deviceID: AudioDeviceID, control: VolumeControl) -> Double? {
        var levels: [Double] = []
        for element in control.elements {
            let propertyAddress = address(control.selector, scope: control.scope, element: element)
            if let level = readFloat(deviceID, propertyAddress) {
                levels.append(Double(level))
            }
        }

        guard !levels.isEmpty else { return nil }
        let average = levels.reduce(0, +) / Double(levels.count)
        return min(max(average, 0), 1)
    }

    @discardableResult
    private func setVolume(_ value: Double, deviceID: AudioDeviceID, control: VolumeControl) -> Bool {
        let level = Float32(min(max(value, 0), 1))
        var succeeded = true
        for element in control.elements {
            var propertyAddress = address(control.selector, scope: control.scope, element: element)
            var newValue = level
            let status = AudioObjectSetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &newValue
            )
            if status != noErr { succeeded = false }
        }
        return succeeded
    }

    private func readMute(deviceID: AudioDeviceID, control: MuteControl) -> Bool? {
        var foundValue = false
        var anyMuted = false
        for element in control.elements {
            let propertyAddress = address(kAudioDevicePropertyMute, scope: control.scope, element: element)
            if let value = readUInt32(deviceID, propertyAddress) {
                foundValue = true
                anyMuted = anyMuted || value != 0
            }
        }
        return foundValue ? anyMuted : nil
    }

    @discardableResult
    private func setMute(_ muted: Bool, deviceID: AudioDeviceID, control: MuteControl) -> Bool {
        var succeeded = true
        for element in control.elements {
            var propertyAddress = address(kAudioDevicePropertyMute, scope: control.scope, element: element)
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
            if status != noErr { succeeded = false }
        }
        return succeeded
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> OSStatus {
        var propertyAddress = address(selector)
        var newValue = deviceID
        return AudioObjectSetPropertyData(
            systemObjectID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &newValue
        )
    }

    // MARK: - CoreAudio helpers

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func readUInt32(_ objectID: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> UInt32? {
        var propertyAddress = propertyAddress
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readFloat(_ objectID: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> Float32? {
        var propertyAddress = propertyAddress
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readString(_ objectID: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> String? {
        var propertyAddress = propertyAddress
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer)
        }

        guard status == noErr, let value else {
            value?.release()
            return nil
        }

        let string = value.takeRetainedValue() as String
        return string
    }

    private func isSettable(_ objectID: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> Bool {
        var propertyAddress = propertyAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &propertyAddress, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    // MARK: - Property listeners

    private func installSystemListeners() {
        guard systemListeners.isEmpty else { return }

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]

        for selector in selectors {
            var propertyAddress = address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleFullRefresh()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &propertyAddress,
                listenerQueue,
                block
            )
            if status == noErr {
                systemListeners.append(PropertyListener(
                    objectID: systemObjectID,
                    address: propertyAddress,
                    block: block
                ))
            }
        }
    }

    private func desiredDeviceListeners() -> [ListenerDescriptor] {
        var descriptors: [ListenerDescriptor] = []

        if let deviceID = defaultOutputID {
            if let control = outputVolumeControl {
                descriptorAppend(control.elements.map {
                    ListenerDescriptor(
                        objectID: deviceID,
                        selector: control.selector,
                        scope: control.scope,
                        element: $0
                    )
                }, to: &descriptors)
            }
            if let control = outputMuteControl {
                descriptorAppend(control.elements.map {
                    ListenerDescriptor(
                        objectID: deviceID,
                        selector: kAudioDevicePropertyMute,
                        scope: control.scope,
                        element: $0
                    )
                }, to: &descriptors)
            }
        }

        if let deviceID = defaultInputID, let control = inputVolumeControl {
            descriptorAppend(control.elements.map {
                ListenerDescriptor(
                    objectID: deviceID,
                    selector: control.selector,
                    scope: control.scope,
                    element: $0
                )
            }, to: &descriptors)
        }

        return descriptors
    }

    private func descriptorAppend(_ new: [ListenerDescriptor], to descriptors: inout [ListenerDescriptor]) {
        for descriptor in new where !descriptors.contains(descriptor) {
            descriptors.append(descriptor)
        }
    }

    private func syncDeviceListeners() {
        let desired = desiredDeviceListeners()
        guard desired != activeDeviceDescriptors else { return }

        removeListeners(deviceListeners)
        deviceListeners.removeAll()
        activeDeviceDescriptors = desired

        for descriptor in desired {
            var propertyAddress = address(
                descriptor.selector,
                scope: descriptor.scope,
                element: descriptor.element
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleLevelRefresh()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                descriptor.objectID,
                &propertyAddress,
                listenerQueue,
                block
            )
            if status == noErr {
                deviceListeners.append(PropertyListener(
                    objectID: descriptor.objectID,
                    address: propertyAddress,
                    block: block
                ))
            }
        }
    }

    private func removeListeners(_ listeners: [PropertyListener]) {
        for listener in listeners {
            var propertyAddress = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &propertyAddress,
                listenerQueue,
                listener.block
            )
        }
    }

    // MARK: - Scheduling and errors

    private func timerFired() {
        refreshLevels()
        timerTick += 1
        if timerTick % 4 == 0 {
            refreshAll()
        }
    }

    private func scheduleFullRefresh() {
        fullRefreshGeneration += 1
        let generation = fullRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, generation == self.fullRefreshGeneration else { return }
            self.refreshAll()
        }
    }

    private func scheduleLevelRefresh() {
        levelRefreshGeneration += 1
        let generation = levelRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, generation == self.levelRefreshGeneration else { return }
            self.refreshLevels()
        }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        errorDismissGeneration += 1
        let generation = errorDismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  generation == self.errorDismissGeneration,
                  self.errorMessage == message else { return }
            self.errorMessage = nil
        }
    }

    private func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AudioManager, Value>,
        _ newValue: Value
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }
}

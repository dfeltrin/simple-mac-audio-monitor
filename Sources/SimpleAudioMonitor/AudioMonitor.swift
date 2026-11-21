import AVFoundation
import AppKit
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
}

@MainActor
final class AudioMonitor: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var selectedDeviceID: AudioDeviceID = 0
    @Published private(set) var availableChannels: [Int] = []
    @Published var selectedChannel = 1 {
        didSet { defaults.set(selectedChannel, forKey: PreferenceKey.selectedChannel) }
    }
    @Published var linkedStereo = false {
        didSet { defaults.set(linkedStereo, forKey: PreferenceKey.linkedStereo) }
    }
    @Published var volume: Float = 0.8 {
        didSet { defaults.set(volume, forKey: PreferenceKey.volume) }
    }
    @Published private(set) var leftOutputLevel: Float = 0
    @Published private(set) var rightOutputLevel: Float = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var isReconnecting = false
    @Published var showError = false
    @Published private(set) var errorMessage = ""

    private var route: MonitorRoute?
    private var recovery: Task<Void, Never>?
    private var meterRefreshTimer: Timer?
    private var routeCheckTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    init() {
        if defaults.object(forKey: PreferenceKey.volume) != nil {
            volume = defaults.float(forKey: PreferenceKey.volume)
        }
        if defaults.object(forKey: PreferenceKey.selectedChannel) != nil {
            selectedChannel = max(1, defaults.integer(forKey: PreferenceKey.selectedChannel))
        }
        linkedStereo = defaults.bool(forKey: PreferenceKey.linkedStereo)
        meterRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMeter()
            }
        }
        routeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRoute()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopForSystemSleep()
            }
        }
    }

    func refreshDevices() {
        devices = Self.inputDevices()
        if let route {
            checkRoute()
            if self.route === route { updateChannels() }
            return
        }
        guard recovery == nil else { return }
        let preferredUID = defaults.string(forKey: PreferenceKey.deviceUID)
        let preferredDevice = devices.first { $0.uid == preferredUID }
        let currentDevice = devices.first { $0.id == selectedDeviceID }
        let defaultInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        select(preferredDevice ?? currentDevice ?? devices.first { $0.id == defaultInput } ?? devices.first)
    }

    func selectDevice(_ device: InputDevice) {
        let resume = route != nil || recovery != nil
        if route?.input.id == device.id { return }
        stop()
        select(device)
        defaults.set(device.uid, forKey: PreferenceKey.deviceUID)
        if resume { start() }
    }

    func applyChannelConfiguration() {
        if linkedStereo, selectedChannel >= (availableChannels.last ?? 1) {
            selectedChannel = max(1, (availableChannels.last ?? 2) - 1)
        }
        if isMonitoring {
            stop()
            start()
        }
    }

    func applyVolume() {
        route?.mixer.outputVolume = volume
    }

    func toggleMonitoring() {
        if isMonitoring || isReconnecting { stop() }
        else { start() }
    }

    func stopForSystemSleep() {
        stop()
    }

    private func start() {
        let selectedUID = devices.first { $0.id == selectedDeviceID }?.uid
            ?? defaults.string(forKey: PreferenceKey.deviceUID)
        devices = Self.inputDevices()
        guard let device = devices.first(where: { $0.uid == selectedUID }) else {
            select(nil)
            report("Connect an audio input device, then try again.")
            return
        }
        guard let outputID = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            report("Connect an audio output device, then try again.")
            return
        }
        start(input: device, outputID: outputID)
    }

    private func start(input device: InputDevice, outputID: AudioDeviceID, retryStalledOutput: Bool = true) {
        select(device)
        defaults.set(device.uid, forKey: PreferenceKey.deviceUID)
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        let input = engine.inputNode
        let meterState = MeterState()
        do {
            guard let inputUnit = input.audioUnit else {
                report("The selected device does not expose an input stream.")
                return
            }
            try setInputDevice(device.id, on: inputUnit)
            try applyInputChannelMap(to: inputUnit)
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
                report("The selected device does not expose an input stream.")
                return
            }
            let output = engine.outputNode
            let outputFormat = output.outputFormat(forBus: 0)
            guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
                report("The selected output device does not expose an audio stream.")
                return
            }
            guard let monitorFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareFormat.sampleRate,
                channels: linkedStereo ? 2 : 1,
                interleaved: false
            ) else {
                report("The selected input format could not be configured.")
                return
            }

            engine.attach(mixer)
            engine.connect(input, to: mixer, format: monitorFormat)
            engine.connect(mixer, to: output, format: nil)
            mixer.outputVolume = volume
            input.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: Self.makeMeterTap(state: meterState))
            try engine.start()
            route = MonitorRoute(engine: engine, mixer: mixer, meterState: meterState,
                                 input: device, outputID: outputID, retryStalledOutput: retryStalledOutput)
            isMonitoring = true
        } catch {
            engine.stop()
            report("Could not start monitoring: \(error.localizedDescription)")
        }
    }

    private func stop() {
        recovery?.cancel()
        recovery = nil
        route?.engine.stop()
        route?.engine.inputNode.removeTap(onBus: 0)
        route = nil
        isMonitoring = false
        isReconnecting = false
        leftOutputLevel = 0
        rightOutputLevel = 0
    }

    private func checkRoute() {
        guard let route else { return }
        if !Self.deviceIsAlive(route.input.id) || !Self.deviceIsAlive(route.outputID)
            || Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) != route.outputID {
            recoverRoute(input: route.input, outputID: route.outputID)
            return
        }

        // The input meter can run without playback. The mixer only renders when the
        // output pulls audio from it, even when the instrument is silent.
        if let time = route.mixer.lastRenderTime, time.isSampleTimeValid, time.sampleTime != route.lastRenderSample {
            if route.lastRenderSample != nil { route.retryStalledOutput = true }
            route.lastRenderSample = time.sampleTime
            route.lastRender = .now
        }
        guard !route.engine.isRunning || route.lastRender.duration(to: .now) >= .seconds(2) else { return }
        if route.retryStalledOutput {
            recoverRoute(input: route.input, outputID: route.outputID)
        } else {
            stop()
            report("The audio output stopped rendering. Check the system output and enable monitoring again.")
        }
    }

    private func recoverRoute(input: InputDevice, outputID: AudioDeviceID) {
        stop()
        isReconnecting = true
        recovery = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self else { return }
                let availableInputs = Self.inputDevices()
                guard let device = availableInputs.first(where: { $0.uid == input.uid }),
                      let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                      Self.deviceIsAlive(output) else { continue }
                // If the interface was both input and output, wait for macOS to
                // restore it after reconnecting instead of playing to a fallback.
                if input.id == outputID, device.id != input.id, output != device.id { continue }
                self.recovery = nil
                self.isReconnecting = false
                self.devices = availableInputs
                self.start(input: device, outputID: output, retryStalledOutput: false)
                return
            }
            guard let self else { return }
            self.recovery = nil
            self.isReconnecting = false
            self.devices = Self.inputDevices()
            self.select(self.devices.first { $0.uid == input.uid })
            self.report("The audio connection could not be restored. Check your audio devices and enable monitoring again.")
        }
    }

    private func refreshMeter() {
        guard let measuredLevel = route?.meterState.load() else { return }
        // Fast attack, slower release: a familiar analog meter response.
        leftOutputLevel = max(measuredLevel.left * volume, leftOutputLevel * 0.82)
        rightOutputLevel = max(measuredLevel.right * volume, rightOutputLevel * 0.82)
    }

    nonisolated private static func makeMeterTap(state: MeterState) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            func rms(_ channel: Int) -> Float {
                let samples = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
                let meanSquare = samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count)
                return min(1, sqrt(meanSquare) * 2.2)
            }
            let left = rms(0)
            let right = buffer.format.channelCount > 1 ? rms(1) : left
            state.store(left: left, right: right)
        }
    }

    private func updateChannels() {
        let channelCount = devices.first(where: { $0.id == selectedDeviceID })?.inputChannels ?? 0
        availableChannels = (0..<channelCount).map { $0 + 1 }
        guard channelCount > 0 else { return }
        if !availableChannels.contains(selectedChannel) {
            selectedChannel = availableChannels.first ?? 1
        }
        if channelCount < 2 { linkedStereo = false }
        if linkedStereo, selectedChannel == channelCount { selectedChannel = channelCount - 1 }
    }

    var canLinkStereo: Bool { availableChannels.count >= 2 }
    var selectedDeviceName: String {
        devices.first(where: { $0.id == selectedDeviceID })?.name ?? "No device selected"
    }

    private func report(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func select(_ device: InputDevice?) {
        selectedDeviceID = device?.id ?? 0
        updateChannels()
    }
}

private final class MonitorRoute {
    let engine: AVAudioEngine
    let mixer: AVAudioMixerNode
    let meterState: MeterState
    let input: InputDevice
    let outputID: AudioDeviceID
    var lastRender = ContinuousClock.now
    var lastRenderSample: AVAudioFramePosition?
    var retryStalledOutput: Bool

    init(engine: AVAudioEngine, mixer: AVAudioMixerNode, meterState: MeterState,
         input: InputDevice, outputID: AudioDeviceID, retryStalledOutput: Bool) {
        self.engine = engine
        self.mixer = mixer
        self.meterState = meterState
        self.input = input
        self.outputID = outputID
        self.retryStalledOutput = retryStalledOutput
    }
}

private enum PreferenceKey {
    static let deviceUID = "preferredInputDeviceUID"
    static let linkedStereo = "linkedStereo"
    static let selectedChannel = "selectedChannel"
    static let volume = "monitorVolume"
}

private final class MeterState: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Float = 0
    private var right: Float = 0

    func store(left: Float, right: Float) {
        lock.lock()
        self.left = left
        self.right = right
        lock.unlock()
    }

    func load() -> (left: Float, right: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (left, right)
    }
}

private extension AudioMonitor {
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    static func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: alive))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func inputDevices() -> [InputDevice] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            let transportType = deviceTransportType(id)
            // Aggregate and virtual devices are often routing helpers (for example
            // loopback drivers), not an instrument input the user wants to monitor.
            guard channels > 0,
                  transportType != kAudioDeviceTransportTypeAggregate,
                  transportType != kAudioDeviceTransportTypeVirtual else { return nil }
            return InputDevice(id: id, uid: deviceUID(id), name: deviceName(id), inputChannels: channels)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func deviceTransportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transportType)
        return status == noErr ? transportType : 0
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name?.takeUnretainedValue() as String? ?? "Audio Input") : "Audio Input"
    }

    static func deviceUID(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (uid?.takeUnretainedValue() as String? ?? "device-\(id)") : "device-\(id)"
    }

    func setInputDevice(_ id: AudioDeviceID, on inputUnit: AudioUnit) throws {
        var mutableID = id
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Core Audio error \(status)"])
        }
    }

    func applyInputChannelMap(to inputUnit: AudioUnit) throws {
        // The AUHAL input node exposes captured channels on output scope / element 1.
        // A channel map keeps channel selection in Core Audio, before the monitor graph,
        // rather than adding an app-level buffer/copy in the render callback.
        let count = linkedStereo ? 2 : 1
        var map: [Int32] = linkedStereo
            ? [Int32(selectedChannel - 1), Int32(selectedChannel)]
            : [Int32(selectedChannel - 1)]
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            1,
            &map,
            UInt32(count * MemoryLayout<Int32>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not select the requested input channel (Core Audio error \(status))."])
        }
    }
}

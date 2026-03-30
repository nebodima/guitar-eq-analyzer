import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioSourceMode: String, CaseIterable {
    case idle = "IDLE"
    case mic = "MIC"
    case file = "FILE"
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class AudioEngineManager: ObservableObject {
    static let eqFrequencies: [Float] = [80, 200, 400, 800, 1600, 3200, 6400]
    static let defaultGains: [Float] = [-6.0, -5.0, -3.0, 1.0, 2.5, 2.5, 0.5]
    static let eqQ: Float = 1.4
    static let eqRange: ClosedRange<Float> = -12...12
    static let outputGain: Float = powf(10, -9.0 / 20.0)

    @Published var mode: AudioSourceMode = .idle
    @Published var eqEnabled = true
    @Published var preFrame = SpectrumFrame(freqs: [], magsDb: [])
    @Published var postFrame = SpectrumFrame(freqs: [], magsDb: [])
    @Published var eqGains: [Float] = defaultGains
    @Published var loadedFileName: String = ""
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var statusText: String = "Ready"

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let micMixer = AVAudioMixerNode()
    private let fileMixer = AVAudioMixerNode()
    private let sourceMixer = AVAudioMixerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 7)
    private let presetStore = PresetStore()

    private var currentFile: AVAudioFile?
    private var displayTimer: DispatchSourceTimer?
    private var analyzer: SpectrumAnalyzer?
    private var isRestartingGraph = false

    init() {
        configureEQ()
        configureGraph()
        loadPresetOnStart()
        refreshDevices()
        startEngineIfNeeded()
        startDisplayUpdates()
        applySourceMode()
    }

    func openFile(url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            currentFile = file
            loadedFileName = url.lastPathComponent
            statusText = "Loaded: \(loadedFileName)"
            if mode == .file {
                startFilePlayback(resetPosition: true)
            }
        } catch {
            statusText = "File error: \(error.localizedDescription)"
        }
    }

    func toggleMic() {
        mode = (mode == .mic) ? .idle : .mic
        applySourceMode()
    }

    func toggleFilePlayback() {
        if mode == .file {
            mode = .idle
            applySourceMode()
            return
        }
        guard currentFile != nil else {
            statusText = "Load a file first"
            return
        }
        mode = .file
        applySourceMode()
    }

    func toggleEQ() {
        eqEnabled.toggle()
        eqNode.bypass = !eqEnabled
        eqNode.globalGain = -9.0
    }

    func resetEQ() {
        eqGains = Array(repeating: 0, count: Self.eqFrequencies.count)
        applyGainsToBands()
    }

    func updateGain(index: Int, value: Float) {
        guard eqGains.indices.contains(index) else { return }
        eqGains[index] = min(max(value, Self.eqRange.lowerBound), Self.eqRange.upperBound)
        eqNode.bands[index].gain = eqGains[index]
    }

    func savePreset() {
        do {
            let url = try presetStore.save(EQPreset(gains: eqGains))
            statusText = "Preset saved: \(url.lastPathComponent)"
        } catch {
            statusText = "Save preset failed: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        inputDevices = Self.fetchAudioDevices(input: true)
        outputDevices = Self.fetchAudioDevices(input: false)
        if selectedInputID == nil {
            selectedInputID = Self.defaultInputDevice()
        }
        if selectedOutputID == nil {
            selectedOutputID = Self.defaultOutputDevice()
        }
    }

    func selectInputDevice(_ deviceID: AudioDeviceID?) {
        guard selectedInputID != deviceID else { return }
        selectedInputID = deviceID
        if setInputDevice(deviceID) {
            statusText = "Input: \(deviceName(for: deviceID, in: inputDevices))"
        } else {
            statusText = "Failed to set input device"
        }
        safeGraphRestartIfRunningMic()
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID?) {
        guard selectedOutputID != deviceID else { return }
        selectedOutputID = deviceID
        if setOutputDevice(deviceID) {
            statusText = "Output: \(deviceName(for: deviceID, in: outputDevices))"
        } else {
            statusText = "Failed to set output device"
        }
        safeGraphRestartIfRunningMic()
    }

    private func configureEQ() {
        for (idx, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqFrequencies[idx]
            band.bandwidth = Self.eqQ
            band.gain = eqGains[idx]
            band.bypass = false
        }
    }

    private func applyGainsToBands() {
        for (idx, gain) in eqGains.enumerated() {
            eqNode.bands[idx].gain = gain
        }
    }

    private func configureGraph() {
        engine.attach(playerNode)
        engine.attach(micMixer)
        engine.attach(fileMixer)
        engine.attach(sourceMixer)
        engine.attach(eqNode)

        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        analyzer = SpectrumAnalyzer(sampleRate: hwFormat.sampleRate)

        engine.connect(engine.inputNode, to: micMixer, format: hwFormat)
        engine.connect(playerNode, to: fileMixer, format: nil)
        engine.connect(micMixer, to: sourceMixer, format: hwFormat)
        engine.connect(fileMixer, to: sourceMixer, format: nil)
        engine.connect(sourceMixer, to: eqNode, format: hwFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: hwFormat)

        sourceMixer.outputVolume = 1.0
        fileMixer.outputVolume = 0.0
        micMixer.outputVolume = 0.0
        eqNode.bypass = !eqEnabled

        installTaps()
    }

    private func installTaps() {
        removeTaps()
        sourceMixer.installTap(onBus: 0, bufferSize: 1024, format: sourceMixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.analyzer?.appendPre(buffer)
        }
        eqNode.installTap(onBus: 0, bufferSize: 1024, format: eqNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.analyzer?.appendPost(buffer)
        }
    }

    private func removeTaps() {
        sourceMixer.removeTap(onBus: 0)
        eqNode.removeTap(onBus: 0)
    }

    private func startEngineIfNeeded() {
        if let id = selectedInputID { _ = setInputDevice(id) }
        if let id = selectedOutputID { _ = setOutputDevice(id) }
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            statusText = "Engine running"
        } catch {
            statusText = "Engine start failed: \(error.localizedDescription)"
        }
    }

    private func startDisplayUpdates() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let analyzer = self.analyzer else { return }
            let frames = analyzer.makeFrames()
            Task { @MainActor in
                self.preFrame = frames.pre
                self.postFrame = frames.post
            }
        }
        timer.resume()
        displayTimer = timer
    }

    private func applySourceMode() {
        startEngineIfNeeded()
        switch mode {
        case .idle:
            micMixer.outputVolume = 0
            fileMixer.outputVolume = 0
            playerNode.pause()
        case .mic:
            micMixer.outputVolume = 1
            fileMixer.outputVolume = 0
            playerNode.pause()
            statusText = "MIC ON (\(deviceName(for: selectedInputID, in: inputDevices)))"
        case .file:
            micMixer.outputVolume = 0
            fileMixer.outputVolume = 1
            startFilePlayback(resetPosition: false)
        }
    }

    private func startFilePlayback(resetPosition: Bool) {
        guard let file = currentFile else {
            statusText = "No file loaded"
            return
        }
        if resetPosition {
            playerNode.stop()
        }
        scheduleFileLoop(file)
        if !playerNode.isPlaying {
            playerNode.play()
        }
        statusText = "FILE PLAY: \(loadedFileName)"
    }

    private func scheduleFileLoop(_ file: AVAudioFile) {
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.mode == .file {
                    self.scheduleFileLoop(file)
                }
            }
        }
    }

    private func loadPresetOnStart() {
        guard let preset = presetStore.load() else { return }
        let normalized = zip(Self.defaultGains.indices, preset.gains).map { _, value in
            min(max(value, Self.eqRange.lowerBound), Self.eqRange.upperBound)
        }
        if normalized.count == Self.defaultGains.count {
            eqGains = normalized
            applyGainsToBands()
            statusText = "Preset loaded"
        }
    }

    private func safeGraphRestartIfRunningMic() {
        guard !isRestartingGraph else { return }
        isRestartingGraph = true
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        if wasRunning {
            do {
                try engine.start()
            } catch {
                statusText = "Engine restart failed: \(error.localizedDescription)"
            }
        }
        isRestartingGraph = false
    }

    private func deviceName(for id: AudioDeviceID?, in devices: [AudioDevice]) -> String {
        guard let id else { return "System default" }
        return devices.first(where: { $0.id == id })?.name ?? "Device \(id)"
    }

    private func setInputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID else { return false }
        guard let inputAU = engine.inputNode.audioUnit else { return false }
        var mutableID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            inputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            size
        )
        return status == noErr
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID else { return false }
        guard let outputAU = engine.outputNode.audioUnit else { return false }
        var mutableID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            outputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            size
        )
        return status == noErr
    }

    private static func fetchAudioDevices(input: Bool) -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let objID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(objID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(objID, &propertyAddress, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard channelCount(for: id, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput) > 0 else {
                return nil
            }
            return AudioDevice(id: id, name: deviceName(for: id))
        }.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private static func channelCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else { return 0 }
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPtr) == noErr else { return 0 }
        let bufferList = bufferListPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &cfName)
        if status == noErr {
            return cfName as String
        }
        return "Device \(deviceID)"
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}

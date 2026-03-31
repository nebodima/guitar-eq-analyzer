import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Accelerate

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
    @Published var preFrame      = SpectrumFrame(freqs: [], magsDb: [])
    @Published var postFrame     = SpectrumFrame(freqs: [], magsDb: [])
    @Published var snapshotFrame = SpectrumFrame(freqs: [], magsDb: [])
    @Published var eqGains: [Float] = defaultGains
    @Published var loadedFileName: String = ""
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var statusText: String = "Ready"
    @Published var isAutoEQRunning = false
    @Published var autoEQProgress: Double = 0
    @Published var namedPresets: [NamedPreset] = []
    @Published var eqCurveFrame = SpectrumFrame(freqs: [], magsDb: [])
    @Published var micPermissionDenied = false
    @Published var canUndo = false
    @Published var showPreEQ = true
    @Published var peakOnPost = false   // false = пики по pre-EQ, true = по post-EQ
    @Published var monitorEnabled = false   // OFF по умолчанию — иначе фидбек с динамиками

    // Сглаженный диапазон отображения (плавная адаптация, не скачет)
    @Published var displayRangeLo: Float = -110
    @Published var displayRangeHi: Float = -40

    // AutoEQ accumulator
    private var accumMags:  [Float] = []
    private var accumCount: Int     = 0
    private var autoEQTimer: DispatchSourceTimer?
    private let autoEQDuration: Double = 4.0

    // Автосохранение — сохраняем через 1 сек после последнего движения слайдера
    private var autoSaveTimer: DispatchSourceTimer?

    // Undo stack (последние 20 состояний)
    private var undoStack: [[Float]] = []
    private let maxUndo = 20

    // ── AutoEQ профили ───────────────────────────────────────────────
    // Полосы: 80  200  400  800  1600  3200  6400 Hz

    struct AutoEQProfile {
        let name:     String
        let icon:     String
        // Целевая форма спектра относительно медианы (dB)
        let target:   [Float]
        // Коэффициент силы коррекции по полосам (0…1)
        let strength: [Float]
        // Гитарный/вокальный диапазон разрешённых значений EQ
        let min:      [Float]
        let max:      [Float]
    }

    static let profiles: [AutoEQProfile] = [
        // ── Guitar ──────────────────────────────────────────────────────
        // Срезаем суб-бас, тело оставляем, поднимаем присутствие 1.6-3.2k
        AutoEQProfile(
            name: "Guitar",
            icon: "guitars",
            target:   [-0.9, -0.5, -0.2,  0.0,  0.2,  0.2, -0.1],
            strength: [0.65, 0.65, 0.65, 0.65, 0.50, 0.40, 0.30],
            min:      [-12.0, -6.0, -5.0, -3.5,  0.0,  0.0, -1.0],
            max:      [ -4.0, -1.0, -0.5, +2.0, +3.5, +2.6, +2.5]
        ),
        // ── Vocal ───────────────────────────────────────────────────────
        // Оставляем тепло 200-400Hz, режем «картон» 300-600Hz аккуратно,
        // поднимаем разборчивость 2-4k, «воздух» на 6.4k
        AutoEQProfile(
            name: "Vocal",
            icon: "mic.fill",
            target:   [ 0.0, -0.5, -1.0, -0.5,  0.5,  1.0,  0.5],
            strength: [0.55, 0.60, 0.65, 0.60, 0.55, 0.50, 0.40],
            min:      [ -6.0, -5.0, -6.0, -4.0, -1.0,  0.0,  0.0],
            max:      [ +1.0,  0.0, +0.5, +1.0, +4.0, +5.0, +4.0]
        ),
        // ── Flat ────────────────────────────────────────────────────────
        // Стремимся к ровному спектру без музыкальных предпочтений
        AutoEQProfile(
            name: "Flat",
            icon: "minus",
            target:   [0.0,  0.0,  0.0,  0.0,  0.0,  0.0,  0.0],
            strength: [0.60, 0.60, 0.60, 0.60, 0.55, 0.45, 0.35],
            min:      [-10.0, -8.0, -8.0, -6.0, -6.0, -6.0, -6.0],
            max:      [ +6.0, +6.0, +6.0, +6.0, +6.0, +6.0, +6.0]
        ),
    ]

    @Published var selectedProfileIndex: Int = 0   // Guitar по умолчанию
    var selectedProfile: AutoEQProfile { Self.profiles[selectedProfileIndex] }

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
        AppLog.clear()
        AppLog.write("=== Guitar EQ Analyzer started ===")
        configureEQ()
        configureGraph()
        // Не загружаем последний пресет — всегда стартуем с шаблонными значениями defaultGains.
        // Для сохранения настроек между сессиями использовать именованные пресеты.
        refreshDevices()
        startEngineIfNeeded()
        startDisplayUpdates()
        applySourceMode()
        namedPresets = presetStore.loadNamed()
        requestMicPermission()
        updateEQCurve()
        AppLog.write("Init complete. inputDevices=\(inputDevices.count) outputDevices=\(outputDevices.count)")

        // Реакция на внешнее изменение конфигурации (смена устройства в macOS, подключение/отключение)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isRestartingGraph else { return }
                AppLog.write("AVAudioEngineConfigurationChange — rebuilding graph")
                self.isRestartingGraph = true
                defer { self.isRestartingGraph = false }
                self.reconnectInputGraph()
                self.engine.prepare()
                do {
                    try self.engine.start()
                    self.logActualDevices()
                    self.applySourceMode()
                    self.refreshDevices()
                    AppLog.write("Engine recovered after config change")
                } catch {
                    self.statusText = "Engine config error: \(error.localizedDescription)"
                    AppLog.write("Engine recovery FAILED: \(error)")
                }
            }
        }
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

    func togglePreEQ() { showPreEQ.toggle() }
    func togglePeakSource() { peakOnPost.toggle() }

    func selectProfile(_ index: Int) {
        guard Self.profiles.indices.contains(index) else { return }
        selectedProfileIndex = index
        statusText = "AutoEQ profile: \(Self.profiles[index].name)"
    }

    func toggleMonitor() {
        monitorEnabled.toggle()
        let vol: Float = (mode == .mic && monitorEnabled) ? 1.0 : (mode == .file ? 1.0 : 0.0)
        engine.mainMixerNode.outputVolume = vol
        AppLog.write("toggleMonitor: monitorEnabled=\(monitorEnabled) mode=\(mode) → mainMixerVol=\(vol) engineRunning=\(engine.isRunning) micMixerVol=\(micMixer.outputVolume)")
    }

    func toggleEQ() {
        eqEnabled.toggle()
        eqNode.bypass = !eqEnabled
    }

    func resetEQ() {
        pushUndo()
        eqGains = Array(repeating: 0, count: Self.eqFrequencies.count)
        applyGainsToBands()
        updateEQCurve()
    }

    func updateGain(index: Int, value: Float) {
        guard eqGains.indices.contains(index) else { return }
        eqGains[index] = min(max(value, Self.eqRange.lowerBound), Self.eqRange.upperBound)
        eqNode.bands[index].gain = eqGains[index]
        updateEQCurve()
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        autoSaveTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.presetStore.saveLastUsed(EQPreset(gains: self.eqGains))
            self.autoSaveTimer = nil
        }
        t.resume()
        autoSaveTimer = t
    }

    func undoEQ() {
        guard let prev = undoStack.popLast() else { return }
        eqGains = prev
        applyGainsToBands()
        updateEQCurve()
        canUndo = !undoStack.isEmpty
        statusText = "Undo"
    }

    func pushUndo() {
        undoStack.append(eqGains)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        canUndo = true
    }

    // ── Snapshot ─────────────────────────────────────────────
    func takeSnapshot() {
        snapshotFrame = preFrame
        statusText    = "Snapshot taken"
    }

    func clearSnapshot() {
        snapshotFrame = SpectrumFrame(freqs: [], magsDb: [])
    }

    // ── AutoEQ ───────────────────────────────────────────────
    func startAutoEQ() {
        guard mode != .idle else { statusText = "Start MIC or File first"; return }
        accumMags  = []
        accumCount = 0
        isAutoEQRunning = true
        autoEQProgress  = 0
        statusText = "Analyzing... play guitar"

        let steps     = 40
        var stepsDone = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: autoEQDuration / Double(steps))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            stepsDone += 1
            self.autoEQProgress = Double(stepsDone) / Double(steps)
            if stepsDone >= steps {
                t.cancel()
                self.autoEQTimer = nil
                self.finishAutoEQ()
            }
        }
        t.resume()
        autoEQTimer = t
    }

    private func finishAutoEQ() {
        isAutoEQRunning = false
        autoEQProgress  = 0
        guard accumCount > 0, !accumMags.isEmpty else {
            statusText = "AutoEQ: no signal captured"
            return
        }
        let avg  = accumMags.map { $0 / Float(accumCount) }
        // Снэпшот «до» чтобы сразу видеть разницу
        snapshotFrame = preFrame
        pushUndo()
        let newGains = computeAutoEQGains(spectrum: avg, freqs: preFrame.freqs)
        eqGains = newGains
        applyGainsToBands()
        updateEQCurve()
        presetStore.saveLastUsed(EQPreset(gains: eqGains))
        statusText = "AutoEQ applied"
    }

    private func computeAutoEQGains(spectrum: [Float], freqs: [Float]) -> [Float] {
        guard !freqs.isEmpty else { return eqGains }

        // 1. Измеряем уровень каждой полосы — среднее в окне 1/3 октавы
        let halfBand = Float(pow(2.0, 1.0 / 6.0))   // ≈ 1.122
        var bandLevels: [Float] = []
        for bandFreq in Self.eqFrequencies {
            let fLo = bandFreq / halfBand
            let fHi = bandFreq * halfBand
            let inBand = zip(freqs, spectrum)
                .filter { $0.0 >= fLo && $0.0 <= fHi }
                .map { $0.1 }
            if !inBand.isEmpty {
                bandLevels.append(inBand.reduce(0, +) / Float(inBand.count))
            } else {
                // резервный вариант: ближайший бин
                let i = freqs.enumerated()
                    .min { abs($0.element - bandFreq) < abs($1.element - bandFreq) }?.offset ?? 0
                bandLevels.append(spectrum[i])
            }
        }

        // 2. Относительные уровни (каждая полоса − медиана полос)
        let sorted   = bandLevels.sorted()
        let median   = sorted[sorted.count / 2]
        let relLevels = bandLevels.map { $0 - median }

        // 3. Параметры из выбранного профиля
        let profile = selectedProfile

        // 4. Ошибка: насколько текущая форма отличается от целевой
        //    error > 0  → нужно поднять  |  error < 0 → нужно срезать
        let errors = zip(relLevels, profile.target).map { rel, target in target - rel }

        // 5. Вычисляем gains: error * strength, затем clip по лимитам профиля.
        return zip(zip(errors, profile.strength),
                   zip(profile.min, profile.max))
            .map { args -> Float in
                let ((err, strength), (minG, maxG)) = args
                return min(max(err * strength, minG), maxG)
            }
    }

    // ── Named Presets ─────────────────────────────────────────
    func saveNamedPreset(name: String) {
        let p = NamedPreset(name: name.isEmpty ? "Preset \(namedPresets.count + 1)" : name,
                            gains: eqGains)
        namedPresets.append(p)
        presetStore.saveNamed(namedPresets)
        statusText = "Saved: \(p.name)"
    }

    func loadNamedPreset(_ preset: NamedPreset) {
        guard preset.gains.count == Self.eqFrequencies.count else { return }
        eqGains = preset.gains
        applyGainsToBands()
        presetStore.saveLastUsed(EQPreset(gains: eqGains))
        statusText = "Loaded: \(preset.name)"
    }

    func deleteNamedPreset(_ preset: NamedPreset) {
        namedPresets.removeAll { $0.id == preset.id }
        presetStore.saveNamed(namedPresets)
    }

    // ── Export ───────────────────────────────────────────────
    func exportEQText() -> String {
        var lines = ["Guitar EQ Settings", "─────────────────────"]
        for (i, f) in Self.eqFrequencies.enumerated() {
            let g    = eqGains[i]
            let sign = g >= 0 ? "+" : ""
            let freq = f >= 1000 ? String(format: "%.0f kHz", f / 1000) : String(format: "%.0f Hz", f)
            lines.append(String(format: "  %-8@ %@%.1f dB", freq as NSString, sign, g))
        }
        lines.append("─────────────────────")
        lines.append("Q = \(Self.eqQ)  |  ±\(Int(Self.eqRange.upperBound)) dB")
        return lines.joined(separator: "\n")
    }

    func copyEQToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportEQText(), forType: .string)
        statusText = "EQ copied to clipboard"
    }

    // ── Legacy (оставляем совместимость) ─────────────────────
    func savePreset() {
        presetStore.saveLastUsed(EQPreset(gains: eqGains))
        statusText = "EQ saved"
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
        Task { await changeDevice(newInput: deviceID, newOutput: nil) }
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID?) {
        // Output switching через CoreAudio property ненадёжно с AVAudioEngine → не меняем
        selectedOutputID = deviceID
    }

    /// Полная смена устройства: stop → set → reconnect graph если input → start
    /// Async чтобы engine.stop() не блокировал main thread (UI не зависает)
    private func changeDevice(newInput: AudioDeviceID?, newOutput: AudioDeviceID?) async {
        guard !isRestartingGraph else { return }
        isRestartingGraph = true

        statusText = "Switching device..."
        // Отдаём управление RunLoop-у чтобы UI успел отрисовать статус до блокирующего stop()
        await Task.yield()

        let wasRunning = engine.isRunning
        AppLog.write("changeDevice: wasRunning=\(wasRunning) newInput=\(String(describing: newInput)) newOutput=\(String(describing: newOutput))")
        if wasRunning { engine.stop() }

        var inputOK  = true
        var outputOK = true

        // Перестраиваем граф — формат inputNode зависит от устройства, поэтому
        // сначала устанавливаем входное устройство (чтобы hwFormat в reconnectInputGraph был верным)
        if let id = newInput  { inputOK  = setInputDevice(id) }

        if !inputOK && newInput != nil {
            statusText = "Input device not available"
            isRestartingGraph = false; return
        }

        // Перестраиваем граф (hwFormat берётся уже от нового input device)
        reconnectInputGraph()

        if wasRunning || mode != .idle {
            // prepare() инициализирует AUHAL-ы. Устройства выставляются ПОСЛЕ prepare()
            // чтобы назначение не было перезаписано внутренней инициализацией.
            engine.prepare()

            // Выставляем output ПОСЛЕ prepare(), чтобы пережить AudioUnitInitialize
            if let id = newOutput { outputOK = setOutputDevice(id) }
            // Явно восстанавливаем output на системный дефолт после смены input:
            // на некоторых macOS setInputDevice меняет shared AUHAL и перенаправляет выход.
            if newInput != nil {
                if let sysOut = Self.defaultOutputDevice() {
                    let ok = setOutputDevice(sysOut)
                    AppLog.write("Output AU → sysDefault \(sysOut): \(ok ? "OK" : "FAIL")")
                }
            }

            do {
                try engine.start()
                logActualDevices()
            } catch let err as NSError where err.code == -10875 {
                AppLog.write("Engine start -10875, retry in 250ms...")
                try? await Task.sleep(nanoseconds: 250_000_000)
                engine.prepare()
                if let id = newInput  { _ = setInputDevice(id) }
                if newInput != nil, let sysOut = Self.defaultOutputDevice() { _ = setOutputDevice(sysOut) }
                do {
                    try engine.start()
                    logActualDevices()
                    AppLog.write("Engine restarted (retry OK)")
                } catch {
                    statusText = "Engine start failed: \(error.localizedDescription)"
                    AppLog.write("Engine restart FAILED after retry: \(error)")
                    isRestartingGraph = false
                    return
                }
            } catch {
                statusText = "Engine start failed: \(error.localizedDescription)"
                AppLog.write("Engine restart FAILED: \(error)")
                isRestartingGraph = false
                return
            }
        }

        // Пауза после смены output — устройству нужно время стабилизироваться
        if newOutput != nil {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        isRestartingGraph = false
        applySourceMode()

        if !outputOK { statusText = "Output device not available" }
        else if newInput  != nil { statusText = "Input: \(deviceName(for: newInput,  in: inputDevices))" }
        else if newOutput != nil { statusText = "Output: \(deviceName(for: newOutput, in: outputDevices))" }
    }

    /// Полная перестройка графа при смене входного устройства
    private func reconnectInputGraph() {
        removeTaps()
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(micMixer)
        engine.disconnectNodeOutput(fileMixer)
        engine.disconnectNodeOutput(sourceMixer)
        engine.disconnectNodeOutput(eqNode)

        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        analyzer = SpectrumAnalyzer(sampleRate: hwFormat.sampleRate)

        engine.connect(engine.inputNode, to: micMixer,    format: hwFormat)
        engine.connect(playerNode,       to: fileMixer,   format: nil)
        engine.connect(micMixer,         to: sourceMixer, format: hwFormat)
        engine.connect(fileMixer,        to: sourceMixer, format: nil)
        engine.connect(sourceMixer,      to: eqNode,      format: hwFormat)
        engine.connect(eqNode,           to: engine.mainMixerNode, format: nil)

        sourceMixer.outputVolume = 1.0
        installTaps()
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
        // Только один tap — на sourceMixer (до EQ).
        // Post-EQ спектр вычисляется математически через eqCurveFrame,
        // что устраняет timing-mismatch, IIR-артефакты и дрейф сглаживания.
        sourceMixer.installTap(onBus: 0, bufferSize: 1024, format: sourceMixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.analyzer?.appendPre(buffer)
        }
    }

    private func removeTaps() {
        sourceMixer.removeTap(onBus: 0)
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()   // обязателен перед start() при запуске/перезапуске
        do {
            try engine.start()
            logActualDevices()
            statusText = "Engine running"
            AppLog.write("Engine started OK")
        } catch {
            statusText = "Engine start failed: \(error.localizedDescription)"
            AppLog.write("Engine start FAILED: \(error)")
        }
    }

    private func startDisplayUpdates() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let analyzer = self.analyzer else { return }
            guard self.mode != .idle else { return }
            let preSpectrum = analyzer.makeFrame()
            Task { @MainActor in
                self.preFrame = preSpectrum

                // Post-EQ: вычисляем математически (pre + EQ-кривая).
                // Гарантирует: при gains=0 → post ≡ pre (кривые совпадают точно).
                // Нет timing-mismatch, нет IIR-артефактов, нет дрейфа сглаживания.
                if !self.eqEnabled || self.eqCurveFrame.freqs.isEmpty {
                    self.postFrame = preSpectrum
                } else {
                    let postMags = self.applyEQCurveToSpectrum(preSpectrum)
                    self.postFrame = SpectrumFrame(freqs: preSpectrum.freqs, magsDb: postMags)
                }

                // Накапливаем для AutoEQ
                if self.isAutoEQRunning, !preSpectrum.magsDb.isEmpty {
                    if self.accumMags.isEmpty {
                        self.accumMags = preSpectrum.magsDb
                    } else if self.accumMags.count == preSpectrum.magsDb.count {
                        for i in self.accumMags.indices { self.accumMags[i] += preSpectrum.magsDb[i] }
                    }
                    self.accumCount += 1
                }
            }
        }
        timer.resume()
        displayTimer = timer
    }

    private func applySourceMode() {
        AppLog.write("applySourceMode: \(mode)")
        switch mode {
        case .idle:
            micMixer.outputVolume = 0
            fileMixer.outputVolume = 0
            engine.mainMixerNode.outputVolume = 0
            playerNode.pause()
            // Не вызываем engine.pause() — start() после pause() без prepare() ненадёжен
            // на macOS при ручном назначении AUHAL устройств.
            // Движок остаётся запущенным, выход заглушён через outputVolume=0.
            statusText = "Ready"
        case .mic:
            startEngineIfNeeded()
            micMixer.outputVolume = 1
            fileMixer.outputVolume = 0
            engine.mainMixerNode.outputVolume = monitorEnabled ? 1.0 : 0.0
            playerNode.pause()
            statusText = "MIC ON (\(deviceName(for: selectedInputID, in: inputDevices)))"
            AppLog.write("applySourceMode MIC: monitor=\(monitorEnabled) mainMixerVol=\(engine.mainMixerNode.outputVolume) micMixerVol=\(micMixer.outputVolume) engineRunning=\(engine.isRunning)")
            logActualDevices()
        case .file:
            startEngineIfNeeded()
            micMixer.outputVolume = 0
            fileMixer.outputVolume = 1
            engine.mainMixerNode.outputVolume = 1.0
            startFilePlayback(resetPosition: false)
        }
    }

    private func startFilePlayback(resetPosition: Bool) {
        guard let file = currentFile else {
            statusText = "No file loaded"
            AppLog.write("startFilePlayback: no file loaded")
            return
        }
        playerNode.stop()
        file.framePosition = 0   // сброс позиции — иначе после смены устройства файл играет с середины или не играет
        scheduleFileLoop(file)
        playerNode.play()
        statusText = "FILE PLAY: \(loadedFileName)"
        AppLog.write("startFilePlayback: playing \(loadedFileName)")
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

    // ── Mic Permission ────────────────────────────────────────
    private func requestMicPermission() {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        if !granted {
                            self?.micPermissionDenied = true
                            self?.statusText = "Microphone access denied"
                        }
                    }
                }
            default:
                micPermissionDenied = true
                statusText = "Microphone access denied — check System Settings"
            }
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor in
                        if !granted {
                            self?.micPermissionDenied = true
                            self?.statusText = "Microphone access denied"
                        }
                    }
                }
            default:
                micPermissionDenied = true
                statusText = "Microphone access denied — check System Settings"
            }
        }
    }

    // ── EQ Curve (biquad frequency response) ─────────────────
    func updateEQCurve() {
        let n     = 300
        let fMin  = Float(60)
        let fMax  = Float(8000)
        var freqs = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            freqs[i] = fMin * pow(fMax / fMin, t)   // log-spaced
        }
        var totalDb = [Float](repeating: 0, count: n)
        for (bandIdx, f0) in Self.eqFrequencies.enumerated() {
            let gain = eqGains[bandIdx]
            guard abs(gain) > 0.05 else { continue }
            let (b, a) = peakingCoeffs(f0: f0, gainDb: gain, Q: Self.eqQ, fs: Float(SAMPLE_RATE))
            for i in 0..<n {
                let w   = 2 * Float.pi * freqs[i] / Float(SAMPLE_RATE)
                let ejw = SIMD2<Float>(cos(w), -sin(w))
                let num = complexAdd(complexAdd(SIMD2<Float>(b[0], 0),
                                               complexMul(SIMD2<Float>(b[1], 0), ejw)),
                                     complexMul(SIMD2<Float>(b[2], 0), complexMul(ejw, ejw)))
                let den = complexAdd(complexAdd(SIMD2<Float>(a[0], 0),
                                               complexMul(SIMD2<Float>(a[1], 0), ejw)),
                                     complexMul(SIMD2<Float>(a[2], 0), complexMul(ejw, ejw)))
                let mag  = sqrt(num.x*num.x + num.y*num.y) / max(sqrt(den.x*den.x + den.y*den.y), 1e-10)
                totalDb[i] += 20 * log10(max(mag, 1e-10))
            }
        }
        eqCurveFrame = SpectrumFrame(freqs: freqs, magsDb: totalDb)
    }

    private let SAMPLE_RATE = 44100

    private func peakingCoeffs(f0: Float, gainDb: Float, Q: Float, fs: Float) -> ([Float], [Float]) {
        let A     = pow(10, gainDb / 40)
        let w0    = 2 * Float.pi * f0 / fs
        let alpha = sin(w0) / (2 * Q)
        let b0 = 1 + alpha * A;  let b1 = -2 * cos(w0);  let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A;  let a1 = -2 * cos(w0);  let a2 = 1 - alpha / A
        return ([b0/a0, b1/a0, b2/a0], [1, a1/a0, a2/a0])
    }

    /// Добавляет значения EQ-кривой к спектру pre-EQ методом линейной интерполяции.
    /// При всех gains=0 eqCurveFrame.magsDb ≡ 0, поэтому result = pre (точно).
    private func applyEQCurveToSpectrum(_ pre: SpectrumFrame) -> [Float] {
        let cf = eqCurveFrame
        guard !cf.freqs.isEmpty, !pre.freqs.isEmpty else { return pre.magsDb }
        return pre.freqs.enumerated().map { idx, freq in
            pre.magsDb[idx] + interpolateEQCurve(cf, at: freq)
        }
    }

    /// Линейная интерполяция по log-spaced eqCurveFrame.
    private func interpolateEQCurve(_ cf: SpectrumFrame, at freq: Float) -> Float {
        let n = cf.freqs.count
        if freq <= cf.freqs[0]     { return cf.magsDb[0] }
        if freq >= cf.freqs[n - 1] { return cf.magsDb[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cf.freqs[mid] <= freq { lo = mid } else { hi = mid }
        }
        let t = (freq - cf.freqs[lo]) / (cf.freqs[hi] - cf.freqs[lo])
        return cf.magsDb[lo] + t * (cf.magsDb[hi] - cf.magsDb[lo])
    }

    private func complexMul(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x)
    }
    private func complexAdd(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { a + b }

    private func loadPresetOnStart() {
        guard let preset = presetStore.loadLastUsed() else { return }
        let normalized = preset.gains.map { min(max($0, Self.eqRange.lowerBound), Self.eqRange.upperBound) }
        if normalized.count == Self.eqFrequencies.count {
            eqGains = normalized
            applyGainsToBands()
            statusText = "Preset loaded"
        }
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
        AppLog.write("setInputDevice \(deviceID) osStatus=\(status)")
        return status == noErr
    }

    /// Читает реально установленные устройства из AUHAL и пишет в лог.
    /// Позволяет сразу видеть, куда идёт звук — в наушники или в Ampero.
    private func logActualDevices() {
        func readDevice(from au: AudioUnit?) -> AudioDeviceID {
            guard let au else { return 0 }
            var id: AudioDeviceID = 0
            var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id, &sz)
            return id
        }
        let inID  = readDevice(from: engine.inputNode.audioUnit)
        let outID = readDevice(from: engine.outputNode.audioUnit)
        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        AppLog.write("AUHAL: input=\(inID)(\(Self.deviceName(for: inID))) output=\(outID)(\(Self.deviceName(for: outID))) outFmt=\(Int(outFmt.sampleRate))Hz/\(outFmt.channelCount)ch")
    }

    @discardableResult
    private func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID, let outputAU = engine.outputNode.audioUnit else { return false }
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
        AppLog.write("setOutputDevice(AU) \(deviceID) osStatus=\(status)")
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

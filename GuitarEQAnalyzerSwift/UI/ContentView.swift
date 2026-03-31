import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var engine: AudioEngineManager
    @StateObject private var perf = PerformanceMonitor()
    @State private var showFileImporter  = false
    @State private var showSaveSheet     = false
    @State private var newPresetName     = ""
    @State private var showPresetsPanel  = false

    var body: some View {
        VStack(spacing: 8) {

            // ── Спектр ───────────────────────────────────────────────
            SpectrumView(
                pre:        engine.showPreEQ ? engine.preFrame : SpectrumFrame(freqs: [], magsDb: []),
                post:       engine.postFrame,
                snapshot:   engine.snapshotFrame,
                eqCurve:    engine.eqCurveFrame,
                fMin: 60,
                fMax: 8000,
                yMin: -120,
                yMax: -10,
                peakSource: engine.peakOnPost ? .post : .pre
            )
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                // Бейдж режима — только когда активен
                if engine.mode != .idle {
                    Label(engine.mode == .mic ? "MIC" : "FILE",
                          systemImage: engine.mode == .mic ? "mic.fill" : "doc.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(modeColor.opacity(0.85), in: Capsule())
                        .padding(10)
                }
            }

            Divider()

            // ── Строка 1: Источник ───────────────────────────────────
            HStack(spacing: 6) {
                // Главные: MIC / File — с текстом
                Button {
                    engine.toggleMic()
                } label: {
                    Label(engine.mode == .mic ? "MIC ON" : "MIC", systemImage: "mic.fill")
                        .frame(minWidth: 50, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.mode == .mic ? .green : .gray.opacity(0.4))
                .keyboardShortcut("m", modifiers: .command)

                // VU-метр — виден только в MIC/Record режиме
                if engine.mode == .mic || engine.isRecording {
                    VUMeterView(levelDb: engine.inputLevelDb)
                        .frame(width: 80, height: 20)
                        .transition(.opacity)
                }

                // Monitor и Record — только в режиме MIC
                if engine.mode == .mic {
                    Button { engine.toggleMonitor() } label: {
                        Label(engine.monitorEnabled ? "Monitor ON" : "Monitor",
                              systemImage: engine.monitorEnabled ? "headphones.circle.fill" : "headphones")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.monitorEnabled ? .green : .gray.opacity(0.4))
                    .help("Hear mic through output device. OFF by default to prevent feedback.")
                    .transition(.opacity.combined(with: .move(edge: .leading)))

                    Button {
                        if engine.isRecording { engine.stopRecording() }
                        else                  { engine.startRecording() }
                    } label: {
                        if engine.isRecording {
                            let m = engine.recordingSeconds / 60
                            let s = engine.recordingSeconds % 60
                            Label(String(format: "● %d:%02d", m, s),
                                  systemImage: "stop.circle.fill")
                                .monospacedDigit()
                                .frame(minWidth: 72, alignment: .leading)
                        } else {
                            Label("Record", systemImage: "record.circle")
                                .frame(minWidth: 72, alignment: .leading)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.isRecording ? .red : .gray.opacity(0.4))
                    .help(engine.isRecording
                          ? "Stop recording — file will be loaded automatically"
                          : "Record mic input to WAV (pre-EQ, dry signal)")
                    .keyboardShortcut("r", modifiers: .command)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Divider().frame(height: 22)

                Button { showFileImporter = true } label: {
                    Label("Open File", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    engine.toggleFilePlayback()
                } label: {
                    Label(engine.mode == .file ? "Stop" : "Play File",
                          systemImage: engine.mode == .file ? "stop.fill" : "play.fill")
                        .frame(minWidth: 54, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.mode == .file ? .orange : .blue)
                .disabled(engine.loadedFileName.isEmpty && engine.mode != .file)
                .keyboardShortcut(.space, modifiers: [])

                if !engine.loadedFileName.isEmpty {
                    Label(engine.loadedFileName, systemImage: "music.note")
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }

                Spacer()

                // Snapshot
                Button { engine.takeSnapshot() } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(.bordered)
                .help("Snapshot: freeze current pre-EQ spectrum for comparison")

                if !engine.snapshotFrame.freqs.isEmpty {
                    Button { engine.clearSnapshot() } label: {
                        Image(systemName: "camera.badge.minus")
                    }
                    .buttonStyle(.bordered)
                    .help("Clear snapshot")
                    .transition(.opacity)
                }

                // Показать папку с записями в Finder
                Button { engine.showRecordingsInFinder() } label: {
                    Label("Recordings", systemImage: "recordingtape")
                }
                .buttonStyle(.bordered)
                .help("Show GuitarEQ Recordings folder in Finder")
            }

            // ── Строка 2: Анализ + Визуализация + Пресеты ───────────────
            HStack(spacing: 6) {
                // AutoEQ
                Button {
                    engine.startAutoEQ()
                } label: {
                    ZStack {
                        Label("AutoEQ", systemImage: "wand.and.stars")
                            .opacity(engine.isAutoEQRunning ? 0 : 1)
                        HStack(spacing: 5) {
                            ProgressView(value: engine.autoEQProgress)
                                .frame(width: 44)
                            Text("Analyzing…")
                        }
                        .opacity(engine.isAutoEQRunning ? 1 : 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(engine.isAutoEQRunning || engine.mode == .idle)
                .help("AutoEQ: analyze then adjust bands (⌘↵)")
                .keyboardShortcut(.return, modifiers: .command)

                // Профиль AutoEQ
                Picker(selection: $engine.selectedProfileIndex, label: EmptyView()) {
                    ForEach(AudioEngineManager.profiles.indices, id: \.self) { i in
                        Text(AudioEngineManager.profiles[i].name).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 162)
                .help("AutoEQ profile: Guitar, Vocal or Flat")

                // Длительность анализа
                Picker(selection: $engine.autoEQDuration, label: EmptyView()) {
                    Text("4s").tag(4.0)
                    Text("8s").tag(8.0)
                    Text("16s").tag(16.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 85)
                .help("AutoEQ analysis duration")

                Divider().frame(height: 22)

                // Визуализация
                Button { engine.togglePreEQ() } label: {
                    Label("Pre-EQ", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.showPreEQ ? .blue : .gray.opacity(0.35))
                .help("Show/hide Pre-EQ spectrum")

                Button { engine.togglePeakSource() } label: {
                    Image(systemName: "waveform.badge.exclamationmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.peakOnPost ? .blue : .gray.opacity(0.35))
                .help(engine.peakOnPost ? "Peaks: Equalized → click for Original"
                                        : "Peaks: Original → click for Equalized")

                Divider().frame(height: 22)

                // Пресеты
                Button { showPresetsPanel.toggle() } label: {
                    Label("Presets", systemImage: "list.star")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showPresetsPanel) {
                    PresetsPanel(engine: engine, showSaveSheet: $showSaveSheet, newPresetName: $newPresetName)
                }

                Button { engine.copyEQToClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Copy EQ to clipboard")

                Spacer()
            }

            // ── Устройства ───────────────────────────────────────────
            HStack(spacing: 12) {
                Label("In:", systemImage: "mic").font(.body).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { engine.selectedInputID ?? 0 },
                    set: { engine.selectInputDevice($0) }
                )) {
                    ForEach(engine.inputDevices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)

                // Output device — только чтение. Менять через macOS: меню 🔊 в строке состояния
                Label("Out:", systemImage: "speaker.wave.2").font(.body).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(engine.outputDevices.first(where: { $0.id == engine.selectedOutputID })?.name ?? "System default")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .help("Output is read-only — change via macOS volume menu in menu bar")
                .frame(maxWidth: 220, alignment: .leading)

                Button { engine.refreshDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh device list")

                Spacer()

                Text(engine.statusText)
                    .font(.body)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Spacer()

                // ── Нагрузка CPU / RAM ────────────────────────────────
                HStack(spacing: 10) {
                    Label {
                        Text(String(format: "%.1f%%", perf.cpuPercent))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .foregroundStyle(perf.cpuPercent > 60 ? .orange : .secondary)

                    Label {
                        Text(String(format: "%.0f MB", perf.memoryMB))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "memorychip")
                    }
                    .foregroundStyle(perf.memoryMB > 300 ? .orange : .secondary)
                }
                .font(.body)
            }

            Divider()

            // ── EQ зона: кнопки управления + слайдеры в одну строку ──
            HStack(alignment: .bottom, spacing: 12) {
                // EQ-кнопки
                VStack(spacing: 6) {
                    Button { engine.toggleEQ() } label: {
                        Label(engine.eqEnabled ? "EQ ON" : "EQ OFF",
                              systemImage: "slider.horizontal.3")
                            .frame(minWidth: 64, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.eqEnabled ? .green : .gray.opacity(0.4))

                    Button { engine.resetEQ() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Reset all bands to 0 dB")

                    Button { engine.undoEQ() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!engine.canUndo)
                    .help("Undo (⌘Z)")
                    .keyboardShortcut("z", modifiers: .command)
                }

                Divider()

                // Слайдеры
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(AudioEngineManager.eqFrequencies.enumerated()), id: \.offset) { idx, freq in
                        EQBandSlider(
                            label: freqLabel(freq),
                            gain: Binding(
                                get: { Double(engine.eqGains[idx]) },
                                set: { engine.updateGain(index: idx, value: Float($0)) }
                            ),
                            range: Double(AudioEngineManager.eqRange.lowerBound)...Double(AudioEngineManager.eqRange.upperBound),
                            onDragStart: { if engine.eqEnabled { engine.pushUndo() } }
                        )
                        .frame(width: 60)
                    }
                }
                .opacity(engine.eqEnabled ? 1.0 : 0.4)

                Spacer()
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .padding(12)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            engine.openFile(url: url)
        }
        .alert("Microphone Access Denied", isPresented: $engine.micPermissionDenied) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Guitar EQ Analyzer needs microphone access to analyze live sound. Enable it in System Settings → Privacy & Security → Microphone.")
        }
    }

    private var modeColor: Color {
        switch engine.mode {
        case .idle: return .gray
        case .mic:  return .green
        case .file: return .blue
        }
    }

    private var statusColor: Color {
        if engine.statusText.lowercased().contains("error") || engine.statusText.lowercased().contains("fail") {
            return .red
        }
        return .secondary
    }

    private func freqLabel(_ f: Float) -> String {
        f >= 1000 ? (floor(f / 1000) == f / 1000 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
    }
}

// ── Панель пресетов ───────────────────────────────────────────────────
struct PresetsPanel: View {
    @ObservedObject var engine: AudioEngineManager
    @Binding var showSaveSheet: Bool
    @Binding var newPresetName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets").font(.headline).padding()
                Spacer()
                Button {
                    newPresetName = ""
                    showSaveSheet = true
                } label: {
                    Label("Save current", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .padding(.trailing)
            }
            Divider()

            if engine.namedPresets.isEmpty {
                Text("No saved presets")
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .padding()
            } else {
                List {
                    ForEach(engine.namedPresets) { preset in
                        HStack {
                            // Звёздочка — пометить как "Мой пресет"
                            Button {
                                engine.setDefaultPreset(preset)
                            } label: {
                                Image(systemName: preset.isDefault ? "star.fill" : "star")
                                    .foregroundStyle(preset.isDefault ? .yellow : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(preset.isDefault ? "This is your default preset" : "Mark as My Preset (loads on startup)")

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(preset.name).font(.body)
                                    if preset.isDefault {
                                        Text("default")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.yellow.opacity(0.15),
                                                        in: Capsule())
                                    }
                                }
                                Text(preset.date, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Load") { engine.loadNamedPreset(preset) }
                                .buttonStyle(.bordered)
                            Button { engine.deleteNamedPreset(preset) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 300)
            }
        }
        .frame(minWidth: 320)
        .sheet(isPresented: $showSaveSheet) {
            VStack(spacing: 16) {
                Text("Save Preset").font(.headline)
                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                HStack(spacing: 12) {
                    Button("Cancel") { showSaveSheet = false }
                        .buttonStyle(.bordered)
                    Button("Save") {
                        engine.saveNamedPreset(name: newPresetName)
                        showSaveSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }
}

// ── Отдельный компонент: вертикальный слайдер полосы EQ ──────────────
struct EQBandSlider: View {
    let label: String
    @Binding var gain: Double
    let range: ClosedRange<Double>
    var onDragStart: (() -> Void)? = nil

    private let sliderHeight: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 4) {
                // dB значение — фиксированная ширина, чтобы не прыгало
                Text(String(format: gain >= 0 ? "+%.1f" : "%.1f", gain))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(gainColor)
                    .frame(width: 42, height: 16)

                // Вертикальный слайдер через drag
                VerticalSlider(value: $gain, range: range, height: sliderHeight,
                               onDragStart: onDragStart)

                // Метка частоты
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(height: 16)
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: sliderHeight + 40)
    }

    private var gainColor: Color {
        if gain > 0.5  { return .green }
        if gain < -0.5 { return .orange }
        return .secondary
    }
}

// ── Нативный вертикальный слайдер через DragGesture ──────────────────
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let height: CGFloat
    var onDragStart: (() -> Void)? = nil

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbY = h * (1 - frac)

            ZStack {
                // Трек
                RoundedRectangle(cornerRadius: 2)
                    .fill(.gray.opacity(0.2))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)

                // Заливка от нуля
                let zeroFrac = CGFloat(-range.lowerBound / (range.upperBound - range.lowerBound))
                let zeroY = h * (1 - zeroFrac)
                let fillTop  = min(thumbY, zeroY)
                let fillH    = abs(zeroY - thumbY)

                Rectangle()
                    .fill(value >= 0 ? Color.green.opacity(0.5) : Color.orange.opacity(0.5))
                    .frame(width: 4, height: max(fillH, 1))
                    .frame(maxWidth: .infinity)
                    .offset(y: fillTop - h / 2 + fillH / 2)

                // Нулевая линия
                Rectangle()
                    .fill(.gray.opacity(0.4))
                    .frame(width: 12, height: 1)
                    .frame(maxWidth: .infinity)
                    .offset(y: zeroY - h / 2)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .offset(y: thumbY - h / 2)
            }
            .contentShape(Rectangle())   // расширяем зону захвата на весь блок
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStart == nil {
                            dragStart = value
                            onDragStart?()   // push undo один раз в начале жеста
                        }
                        let delta = -Double(drag.translation.height / h) * (range.upperBound - range.lowerBound)
                        value = min(max((dragStart ?? value) + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = 0 }  // двойной тап — сброс в 0
        }
        .frame(width: 30, height: height)
        .frame(maxWidth: 30)
    }
}

// ── VU-метр ───────────────────────────────────────────────────────────
struct VUMeterView: View {
    let levelDb: Float
    // Диапазон отображения: -60 dB (тишина) … 0 dB (максимум)
    private let minDb: Float = -60
    private let maxDb: Float =  0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frac = CGFloat(max(0, min(1, (levelDb - minDb) / (maxDb - minDb))))

            ZStack(alignment: .leading) {
                // Фон
                RoundedRectangle(cornerRadius: 3)
                    .fill(.gray.opacity(0.2))

                // Заливка — зелёная до -6dB, жёлтая до -3dB, красная выше
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: w * frac)

                // Отметка -6 dB (безопасный уровень)
                let safeX = w * CGFloat((-6 - minDb) / (maxDb - minDb))
                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 1, height: h)
                    .offset(x: safeX)
            }
        }
    }

    private var barColor: Color {
        if levelDb > -3  { return .red }
        if levelDb > -6  { return .yellow }
        return .green
    }
}

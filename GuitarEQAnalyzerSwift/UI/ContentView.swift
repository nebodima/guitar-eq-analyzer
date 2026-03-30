import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var engine: AudioEngineManager
    @State private var showFileImporter  = false
    @State private var showSaveSheet     = false
    @State private var newPresetName     = ""
    @State private var showPresetsPanel  = false

    var body: some View {
        VStack(spacing: 8) {

            // ── Спектр ───────────────────────────────────────────────
            SpectrumView(
                pre:      engine.preFrame,
                post:     engine.postFrame,
                snapshot: engine.snapshotFrame,
                eqCurve:  engine.eqCurveFrame,
                fMin: 60,
                fMax: 8000,
                yMin: -110,
                yMax: -40
            )
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                // Пиктограмма режима
                Label(engine.mode == .idle ? "Idle" : engine.mode == .mic ? "MIC" : "FILE",
                      systemImage: engine.mode == .mic ? "mic.fill" : engine.mode == .file ? "doc.fill" : "pause.circle")
                    .font(.caption2)
                    .foregroundStyle(engine.mode == .idle ? .gray : .white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(modeColor.opacity(0.75), in: Capsule())
                    .padding(10)
            }

            Divider()

            // ── Источник звука ───────────────────────────────────────
            HStack(spacing: 8) {
                // MIC
                Button {
                    engine.toggleMic()
                } label: {
                    Label(engine.mode == .mic ? "MIC ON" : "MIC", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.mode == .mic ? .green : .gray.opacity(0.4))

                // Файл
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open File", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    engine.toggleFilePlayback()
                } label: {
                    Label(engine.mode == .file ? "Stop" : "Play File",
                          systemImage: engine.mode == .file ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.mode == .file ? .orange : .blue)
                .disabled(engine.loadedFileName.isEmpty && engine.mode != .file)

                // Имя файла
                if !engine.loadedFileName.isEmpty {
                    Label(engine.loadedFileName, systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }

                // Snapshot
                Button {
                    engine.takeSnapshot()
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .help("Freeze current pre-EQ spectrum for comparison")

                if !engine.snapshotFrame.freqs.isEmpty {
                    Button { engine.clearSnapshot() } label: {
                        Image(systemName: "camera.badge.minus")
                    }
                    .buttonStyle(.bordered)
                    .help("Clear snapshot")
                }

                Spacer()

                // AutoEQ
                Button {
                    engine.startAutoEQ()
                } label: {
                    if engine.isAutoEQRunning {
                        HStack(spacing: 5) {
                            ProgressView(value: engine.autoEQProgress)
                                .frame(width: 50)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("AutoEQ", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(engine.isAutoEQRunning || engine.mode == .idle)
                .help("Play guitar for 4 sec, AutoEQ will flatten the response")

                // EQ
                Button {
                    engine.toggleEQ()
                } label: {
                    Label(engine.eqEnabled ? "EQ ON" : "EQ OFF", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.eqEnabled ? .blue : .gray.opacity(0.4))

                Button("Reset EQ") { engine.resetEQ() }
                    .buttonStyle(.bordered)

                Button { engine.undoEQ() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(!engine.canUndo)
                .keyboardShortcut("z", modifiers: .command)

                // Presets
                Button {
                    showPresetsPanel.toggle()
                } label: {
                    Label("Presets", systemImage: "list.star")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showPresetsPanel) {
                    PresetsPanel(engine: engine, showSaveSheet: $showSaveSheet, newPresetName: $newPresetName)
                }

                // Export
                Button {
                    engine.copyEQToClipboard()
                } label: {
                    Label("Copy EQ", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Copy EQ settings to clipboard (paste into DAW or notes)")
            }

            // ── Устройства ───────────────────────────────────────────
            HStack(spacing: 12) {
                Label("In:", systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { engine.selectedInputID ?? 0 },
                    set: { engine.selectInputDevice($0) }
                )) {
                    ForEach(engine.inputDevices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)

                Label("Out:", systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { engine.selectedOutputID ?? 0 },
                    set: { engine.selectOutputDevice($0) }
                )) {
                    ForEach(engine.outputDevices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)

                Button { engine.refreshDevices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh device list")

                Spacer()

                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Divider()

            // ── EQ Слайдеры ──────────────────────────────────────────
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(AudioEngineManager.eqFrequencies.enumerated()), id: \.offset) { idx, freq in
                    EQBandSlider(
                        label: freqLabel(freq),
                        gain: Binding(
                            get: { Double(engine.eqGains[idx]) },
                            set: { engine.updateGain(index: idx, value: Float($0)) }
                        ),
                        range: Double(AudioEngineManager.eqRange.lowerBound)...Double(AudioEngineManager.eqRange.upperBound)
                    )
                }
            }
            .padding(.horizontal, 4)
            .opacity(engine.eqEnabled ? 1.0 : 0.4)
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
                    .font(.caption)
                    .padding()
            } else {
                List {
                    ForEach(engine.namedPresets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.body)
                                Text(preset.date, style: .date)
                                    .font(.caption2).foregroundStyle(.secondary)
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

    private let sliderHeight: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 4) {
                // dB значение
                Text(String(format: gain >= 0 ? "+%.1f" : "%.1f", gain))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(gainColor)
                    .frame(height: 14)

                // Вертикальный слайдер через drag
                VerticalSlider(value: $gain, range: range, height: sliderHeight)

                // Метка частоты
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: sliderHeight + 36)
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStart == nil { dragStart = value }
                        let delta = -Double(drag.translation.height / h) * (range.upperBound - range.lowerBound)
                        value = min(max((dragStart ?? value) + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = 0 }  // двойной тап — сброс в 0
        }
        .frame(width: 30, height: height)
        .frame(maxWidth: .infinity)
    }
}

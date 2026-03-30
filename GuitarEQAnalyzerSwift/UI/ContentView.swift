import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var engine: AudioEngineManager
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 10) {
            SpectrumView(
                pre: engine.preFrame,
                post: engine.postFrame,
                fMin: 60,
                fMax: 8000,
                yMin: -110,
                yMax: -40
            )
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button(engine.mode == .mic ? "MIC ON" : "MIC OFF") {
                    engine.toggleMic()
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.mode == .mic ? .green : .gray)

                Button("Open File") {
                    showFileImporter = true
                }
                .buttonStyle(.borderedProminent)

                Button(engine.mode == .file ? "Stop File" : "Play File") {
                    engine.toggleFilePlayback()
                }
                .buttonStyle(.bordered)

                Button(engine.eqEnabled ? "EQ ON" : "EQ OFF") {
                    engine.toggleEQ()
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.eqEnabled ? .blue : .gray)

                Button("Reset") {
                    engine.resetEQ()
                }
                .buttonStyle(.bordered)

                Button("Save EQ") {
                    engine.savePreset()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            HStack {
                Picker("Input", selection: Binding(
                    get: { engine.selectedInputID ?? 0 },
                    set: { engine.selectInputDevice($0) }
                )) {
                    ForEach(engine.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .frame(minWidth: 360)

                Picker("Output", selection: Binding(
                    get: { engine.selectedOutputID ?? 0 },
                    set: { engine.selectOutputDevice($0) }
                )) {
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .frame(minWidth: 360)

                Button("Refresh Devices") {
                    engine.refreshDevices()
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(AudioEngineManager.eqFrequencies.enumerated()), id: \.offset) { idx, freq in
                    VStack(spacing: 6) {
                        Text(label(for: freq))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(engine.eqGains[idx]) },
                                set: { engine.updateGain(index: idx, value: Float($0)) }
                            ),
                            in: Double(AudioEngineManager.eqRange.lowerBound)...Double(AudioEngineManager.eqRange.upperBound),
                            step: 0.1
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 120, height: 22)
                        Text(String(format: "%.1f dB", engine.eqGains[idx]))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    .frame(width: 72)
                }
            }
            .padding(.top, 8)

            HStack {
                Text(engine.loadedFileName.isEmpty ? "No file loaded" : engine.loadedFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            engine.openFile(url: url)
        }
    }

    private func label(for freq: Float) -> String {
        if freq >= 1000 {
            let k = freq / 1000
            return floor(k) == k ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
        }
        return "\(Int(freq))Hz"
    }
}

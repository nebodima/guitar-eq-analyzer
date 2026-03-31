import Accelerate
import AVFoundation
import Foundation

struct SpectrumFrame {
    let freqs: [Float]
    let magsDb: [Float]
}

final class SpectrumAnalyzer {
    private let sampleRate: Double
    private let fftSize: Int
    private let fMin: Float
    private let fMax: Float
    private let smoothing: Float

    private let preBuffer: RingBuffer

    private let dft: vDSP.DFT<Float>
    private let window: [Float]
    private let freqAxis: [Float]
    private let visibleIndices: [Int]
    private let visibleFreqs: [Float]

    // Предвычисленные окна 1/3-октавного сглаживания по видимым бинам.
    // Каждый элемент — (lo, hi) индексы в массиве visibleIndices.
    // Вычисляется один раз в init → O(1) на кадр вместо O(n²).
    private let smoothWindows: [(lo: Int, hi: Int)]

    private var smoothedPre: [Float]?

    init(sampleRate: Double, fftSize: Int = 4096, fMin: Float = 60, fMax: Float = 8000, smoothing: Float = 0.75) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.fMin = fMin
        self.fMax = fMax
        self.smoothing = smoothing
        self.preBuffer = RingBuffer(capacity: fftSize * 8)
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)

        var freqs: [Float] = []
        freqs.reserveCapacity((fftSize / 2) + 1)
        for i in 0...(fftSize / 2) {
            freqs.append(Float(i) * Float(sampleRate) / Float(fftSize))
        }
        self.freqAxis = freqs

        let visible = freqs.enumerated().compactMap { idx, f in
            (f >= fMin && f <= fMax) ? idx : nil
        }
        self.visibleIndices = visible
        self.visibleFreqs = visible.map { freqs[$0] }

        // Предвычисляем окна 1/3 октавы: halfBand = 2^(1/6) ≈ 1.122
        // Для каждого видимого бина i находим lo..hi в visibleFreqs через бинарный поиск.
        let halfBand = Float(pow(2.0, 1.0 / 6.0))
        let vf = visible.map { freqs[$0] }
        var windows = [(lo: Int, hi: Int)]()
        windows.reserveCapacity(vf.count)
        for (i, f) in vf.enumerated() {
            let fLo = f / halfBand
            let fHi = f * halfBand
            // Бинарный поиск нижней границы
            var lo = 0, hi = vf.count - 1
            while lo < hi { let m = (lo + hi) / 2; if vf[m] < fLo { lo = m + 1 } else { hi = m } }
            let loIdx = lo
            // Бинарный поиск верхней границы
            lo = i; hi = vf.count - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if vf[m] <= fHi { lo = m } else { hi = m - 1 } }
            let hiIdx = max(loIdx, lo)
            windows.append((lo: loIdx, hi: hiIdx))
        }
        self.smoothWindows = windows

        guard let dft = vDSP.DFT(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
            fatalError("Unable to initialize vDSP.DFT")
        }
        self.dft = dft
    }

    func appendPre(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData?.pointee else { return }
        preBuffer.append(src, count: Int(buffer.frameLength))
    }

    /// Возвращает только pre-EQ спектр.
    /// Post-EQ вычисляется в AudioEngineManager математически через eqCurveFrame,
    /// что гарантирует идентичность кривых при gains=0 и исключает timing-mismatch.
    func makeFrame() -> SpectrumFrame {
        computeSpectrum(from: preBuffer.snapshot(last: fftSize), smoothed: &smoothedPre)
    }

    private func computeSpectrum(from samples: [Float], smoothed: inout [Float]?) -> SpectrumFrame {
        var input = samples
        vDSP.multiply(input, window, result: &input)

        var inputImag = Array(repeating: Float.zero, count: fftSize)
        var real = Array(repeating: Float.zero, count: fftSize)
        var imag = Array(repeating: Float.zero, count: fftSize)
        dft.transform(inputReal: input, inputImaginary: inputImag, outputReal: &real, outputImaginary: &imag)

        var mags = Array(repeating: Float.zero, count: (fftSize / 2) + 1)
        mags[0] = abs(real[0])
        for i in 1..<(fftSize / 2) {
            let r = real[i]
            let im = imag[i]
            mags[i] = sqrtf((r * r) + (im * im))
        }
        mags[fftSize / 2] = abs(real[fftSize / 2])

        var scale = Float(1.0 / Float(fftSize))
        vDSP.multiply(scale, mags, result: &mags)

        for i in mags.indices {
            if mags[i] < 1e-8 { mags[i] = 1e-8 }
        }

        var magsDb = Array(repeating: Float.zero, count: mags.count)
        vDSP.convert(amplitude: mags, toDecibels: &magsDb, zeroReference: 1.0)

        // Временно́е сглаживание (по времени — между кадрами)
        if let prev = smoothed, prev.count == magsDb.count {
            let a = smoothing, b = 1.0 - a
            for i in magsDb.indices { magsDb[i] = a * prev[i] + b * magsDb[i] }
            smoothed = magsDb
        } else {
            smoothed = magsDb
        }

        // Извлекаем видимые бины
        let raw = visibleIndices.map { smoothed![$0] }

        // Частотное сглаживание 1/3 октавы через предвычисленные окна + prefix sum → O(n)
        let values = freqSmooth(raw)

        return SpectrumFrame(freqs: visibleFreqs, magsDb: values)
    }

    /// O(n) 1/3-октавное сглаживание через prefix sum.
    /// Предвычисленные окна (smoothWindows) гарантируют нулевые аллокации на горячем пути.
    private func freqSmooth(_ raw: [Float]) -> [Float] {
        let n = raw.count
        guard n > 1 else { return raw }

        // Prefix sum: prefix[i+1] = sum(raw[0...i])
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + raw[i] }

        return smoothWindows.map { w in
            let count = w.hi - w.lo + 1
            return (prefix[w.hi + 1] - prefix[w.lo]) / Float(count)
        }
    }
}

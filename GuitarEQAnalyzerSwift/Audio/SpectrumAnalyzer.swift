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
    private let visibleIndices: [Int]
    private let visibleFreqs: [Float]
    private let smoothWindows: [(lo: Int, hi: Int)]

    // ── Предвыделенные рабочие буферы — нет аллокаций на горячем пути ──
    private var bufInput:     [Float]
    private var bufInputImag: [Float]
    private var bufReal:      [Float]
    private var bufImag:      [Float]
    private var bufMags:      [Float]
    private var bufMagsDb:    [Float]
    private var bufSmoothed:  [Float]
    private var bufRaw:       [Float]
    private var bufPrefix:    [Float]
    private var bufR2:        [Float]
    private var bufI2:        [Float]
    private var bufTmp:       [Float]
    private var hasSmoothed = false

    init(sampleRate: Double, fftSize: Int = 2048,
         fMin: Float = 60, fMax: Float = 8000, smoothing: Float = 0.75) {
        self.sampleRate = sampleRate
        self.fftSize    = fftSize
        self.fMin       = fMin
        self.fMax       = fMax
        self.smoothing  = smoothing
        self.preBuffer  = RingBuffer(capacity: fftSize * 8)
        self.window     = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                      count: fftSize, isHalfWindow: false)

        // Частотная ось
        let binHz = Float(sampleRate) / Float(fftSize)
        var freqs = [Float](repeating: 0, count: (fftSize / 2) + 1)
        for i in freqs.indices { freqs[i] = Float(i) * binHz }

        let visible = freqs.enumerated().compactMap { idx, f in
            (f >= fMin && f <= fMax) ? idx : nil
        }
        self.visibleIndices = visible
        self.visibleFreqs   = visible.map { freqs[$0] }

        // Предвычисляем окна 1/3 октавы один раз в init
        let halfBand = Float(pow(2.0, 1.0 / 6.0))
        let vf = visible.map { freqs[$0] }
        var windows = [(lo: Int, hi: Int)]()
        windows.reserveCapacity(vf.count)
        for (i, f) in vf.enumerated() {
            let fLo = f / halfBand, fHi = f * halfBand
            var lo = 0, hi = vf.count - 1
            while lo < hi { let m = (lo+hi)/2; if vf[m] < fLo { lo = m+1 } else { hi = m } }
            let loIdx = lo; lo = i; hi = vf.count - 1
            while lo < hi { let m = (lo+hi+1)/2; if vf[m] <= fHi { lo = m } else { hi = m-1 } }
            windows.append((lo: loIdx, hi: max(loIdx, lo)))
        }
        self.smoothWindows = windows

        guard let dft = vDSP.DFT(count: fftSize, direction: .forward,
                                  transformType: .complexComplex, ofType: Float.self) else {
            fatalError("Unable to initialize vDSP.DFT")
        }
        self.dft = dft

        // Инициализируем буферы один раз
        let half = (fftSize / 2) + 1
        bufInput     = [Float](repeating: 0, count: fftSize)
        bufInputImag = [Float](repeating: 0, count: fftSize)
        bufReal      = [Float](repeating: 0, count: fftSize)
        bufImag      = [Float](repeating: 0, count: fftSize)
        bufMags      = [Float](repeating: 0, count: half)
        bufMagsDb    = [Float](repeating: 0, count: half)
        bufSmoothed  = [Float](repeating: -80, count: half)
        bufRaw       = [Float](repeating: 0, count: vf.count)
        bufPrefix    = [Float](repeating: 0, count: vf.count + 1)
        bufR2        = [Float](repeating: 0, count: half - 1)
        bufI2        = [Float](repeating: 0, count: half - 1)
        bufTmp       = [Float](repeating: 0, count: half)
    }

    func appendPre(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData?.pointee else { return }
        preBuffer.append(src, count: Int(buffer.frameLength))
    }

    func makeFrame() -> SpectrumFrame { computeSpectrum() }

    private func computeSpectrum() -> SpectrumFrame {
        let half = (fftSize / 2) + 1

        // 1. Snapshot → bufInput без аллокации, применяем окно
        let snap = preBuffer.snapshot(last: fftSize)
        let copyLen = min(snap.count, fftSize)
        if copyLen < fftSize { vDSP.fill(&bufInput, with: 0) }
        snap.withUnsafeBufferPointer { src in
            bufInput.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress, src.baseAddress,
                       copyLen * MemoryLayout<Float>.stride)
            }
        }
        vDSP.multiply(bufInput, window, result: &bufInput)

        // 2. FFT
        vDSP.fill(&bufInputImag, with: 0)
        dft.transform(inputReal: bufInput, inputImaginary: bufInputImag,
                      outputReal: &bufReal, outputImaginary: &bufImag)

        // 3. Магнитуды через vDSP (векторизовано)
        bufMags[0] = abs(bufReal[0])
        vDSP.multiply(bufReal[1..<half], bufReal[1..<half], result: &bufR2)
        vDSP.multiply(bufImag[1..<half], bufImag[1..<half], result: &bufI2)
        vDSP.add(bufR2, bufI2, result: &bufR2)
        var n = Int32(half - 1)
        vvsqrtf(&bufR2, bufR2, &n)
        for i in 0..<(half - 1) { bufMags[i + 1] = bufR2[i] }

        // 4. Масштаб + clamp + dB
        let scale = Float(1.0 / Float(fftSize))
        vDSP.multiply(scale, bufMags, result: &bufMags)
        let threshold: Float = 1e-8
        vDSP.threshold(bufMags, to: threshold, with: .clampToThreshold, result: &bufMags)
        vDSP.convert(amplitude: bufMags, toDecibels: &bufMagsDb, zeroReference: 1.0)

        // 5. Временно́е сглаживание без аллокации
        if hasSmoothed {
            let a = smoothing, b = 1.0 - smoothing
            // bufSmoothed = a * bufSmoothed + b * bufMagsDb
            vDSP.multiply(a, bufSmoothed, result: &bufSmoothed)
            vDSP.multiply(b, bufMagsDb, result: &bufTmp)
            vDSP.add(bufSmoothed, bufTmp, result: &bufSmoothed)
        } else {
            bufSmoothed = bufMagsDb
            hasSmoothed = true
        }

        // 6. Извлекаем видимые бины → bufRaw
        for (j, idx) in visibleIndices.enumerated() { bufRaw[j] = bufSmoothed[idx] }

        // 7. 1/3-октавное сглаживание через prefix sum (без аллокации)
        bufPrefix[0] = 0
        for i in 0..<bufRaw.count { bufPrefix[i + 1] = bufPrefix[i] + bufRaw[i] }
        let values = smoothWindows.map { w -> Float in
            (bufPrefix[w.hi + 1] - bufPrefix[w.lo]) / Float(w.hi - w.lo + 1)
        }

        return SpectrumFrame(freqs: visibleFreqs, magsDb: values)
    }
}

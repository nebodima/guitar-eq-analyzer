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
    private let postBuffer: RingBuffer

    private let dft: vDSP.DFT<Float>
    private let window: [Float]
    private let freqAxis: [Float]
    private let visibleIndices: [Int]

    private var smoothedPre: [Float]?
    private var smoothedPost: [Float]?

    init(sampleRate: Double, fftSize: Int = 4096, fMin: Float = 60, fMax: Float = 8000, smoothing: Float = 0.75) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.fMin = fMin
        self.fMax = fMax
        self.smoothing = smoothing
        self.preBuffer = RingBuffer(capacity: fftSize * 8)
        self.postBuffer = RingBuffer(capacity: fftSize * 8)
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)

        var freqs: [Float] = []
        freqs.reserveCapacity((fftSize / 2) + 1)
        for i in 0...(fftSize / 2) {
            freqs.append(Float(i) * Float(sampleRate) / Float(fftSize))
        }
        self.freqAxis = freqs
        self.visibleIndices = freqs.enumerated().compactMap { idx, f in
            (f >= fMin && f <= fMax) ? idx : nil
        }

        guard let dft = vDSP.DFT(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
            fatalError("Unable to initialize vDSP.DFT")
        }
        self.dft = dft
    }

    func appendPre(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData?.pointee else { return }
        preBuffer.append(src, count: Int(buffer.frameLength))
    }

    func appendPost(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData?.pointee else { return }
        postBuffer.append(src, count: Int(buffer.frameLength))
    }

    func makeFrames() -> (pre: SpectrumFrame, post: SpectrumFrame) {
        let pre = computeSpectrum(from: preBuffer.snapshot(last: fftSize), smoothed: &smoothedPre)
        let post = computeSpectrum(from: postBuffer.snapshot(last: fftSize), smoothed: &smoothedPost)
        return (pre: pre, post: post)
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
            if mags[i] < 1e-8 {
                mags[i] = 1e-8
            }
        }

        var magsDb = Array(repeating: Float.zero, count: mags.count)
        vDSP.convert(amplitude: mags, toDecibels: &magsDb, zeroReference: 1.0)

        if let prev = smoothed, prev.count == magsDb.count {
            var mixed = Array(repeating: Float.zero, count: magsDb.count)
            let a = smoothing
            let b = Float(1.0) - a
            for i in mixed.indices {
                mixed[i] = (a * prev[i]) + (b * magsDb[i])
            }
            smoothed = mixed
        } else {
            smoothed = magsDb
        }

        let values = visibleIndices.map { smoothed?[$0] ?? -120 }
        let freqs = visibleIndices.map { freqAxis[$0] }
        return SpectrumFrame(freqs: freqs, magsDb: values)
    }
}

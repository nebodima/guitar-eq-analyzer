import SwiftUI

struct SpectrumView: View {
    let pre:      SpectrumFrame
    let post:     SpectrumFrame
    let snapshot: SpectrumFrame
    let eqCurve:  SpectrumFrame
    let fMin: Float
    let fMax: Float
    let yMin: Float   // нижний предел по умолчанию
    let yMax: Float   // верхний предел по умолчанию

    // Адаптивный диапазон по текущему сигналу
    private var dynRange: (lo: Float, hi: Float) {
        let all = pre.magsDb + post.magsDb
        guard !all.isEmpty else { return (yMin, yMax) }
        let valid = all.filter { $0 > -140 }
        guard !valid.isEmpty else { return (yMin, yMax) }
        let hi  = valid.max()! + 8
        let lo  = valid.min()! - 10
        return (max(lo, yMin), min(hi, 0))
    }

    var body: some View {
        let (lo, hi) = dynRange
        return GeometryReader { geo in
            let lp: CGFloat = 42      // left padding (Y labels)
            let bp: CGFloat = 20      // bottom padding (X labels)
            let w = geo.size.width  - lp - 8
            let h = geo.size.height - bp - 8

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.92)

                // ── Canvas ────────────────────────────────────────────
                Canvas { ctx, _ in
                    drawGrid(ctx: &ctx, w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    drawResonanceZones(ctx: &ctx, frame: pre, w: w, h: h, ox: lp, oy: 8)
                    if !snapshot.freqs.isEmpty {
                        drawLine(ctx: &ctx, frame: snapshot, color: .yellow.opacity(0.65),
                                 w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi, dash: [5, 3])
                    }
                    drawLine(ctx: &ctx, frame: pre,  color: .blue.opacity(0.85),
                             w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    drawLine(ctx: &ctx, frame: post, color: .green.opacity(0.95),
                             w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    if !eqCurve.freqs.isEmpty, !pre.magsDb.isEmpty {
                        let mid    = pre.magsDb.reduce(0, +) / Float(pre.magsDb.count)
                        let shifted = SpectrumFrame(freqs: eqCurve.freqs,
                                                    magsDb: eqCurve.magsDb.map { $0 + mid })
                        drawLine(ctx: &ctx, frame: shifted, color: .orange.opacity(0.85),
                                 w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    }
                }

                // ── Метки dB ─────────────────────────────────────────
                let ticks = dbTicks(lo: lo, hi: hi)
                ForEach(ticks, id: \.self) { db in
                    let y = 8 + CGFloat(yFrac(db: db, lo: lo, hi: hi)) * h
                    Text("\(Int(db))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray.opacity(0.7))
                        .frame(width: lp - 4, alignment: .trailing)
                        .position(x: (lp - 4) / 2, y: y)
                }

                // ── Метки Hz ─────────────────────────────────────────
                ForEach(freqTicks, id: \.self) { f in
                    let x = lp + CGFloat(xFrac(f)) * w
                    Text(freqLabel(f))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray.opacity(0.7))
                        .position(x: x, y: geo.size.height - bp / 2 - 2)
                }

                // ── Легенда ───────────────────────────────────────────
                VStack(alignment: .leading, spacing: 3) {
                    Label("Pre-EQ",   systemImage: "waveform").foregroundStyle(.blue)
                    Label("Post-EQ",  systemImage: "waveform").foregroundStyle(.green)
                    Label("EQ curve", systemImage: "slider.horizontal.3").foregroundStyle(.orange)
                    if !snapshot.freqs.isEmpty {
                        Label("Snapshot", systemImage: "camera").foregroundStyle(.yellow)
                    }
                }
                .font(.caption2)
                .padding(7)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 12).padding(.leading, lp + 6)

                // ── Пик ──────────────────────────────────────────────
                if let pk = peakInfo(frame: post) {
                    let px = lp + CGFloat(xFrac(pk.freq)) * w
                    let py = 8 + CGFloat(yFrac(db: pk.db, lo: lo, hi: hi)) * h
                    Canvas { ctx, _ in
                        var p = Path(); p.move(to: CGPoint(x: px, y: 8))
                        p.addLine(to: CGPoint(x: px, y: 8 + h))
                        ctx.stroke(p, with: .color(.yellow.opacity(0.3)), lineWidth: 0.8)
                    }
                    Text("\(freqLabel(pk.freq))  \(String(format: "%.0f", pk.db)) dB")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .position(x: min(max(px, lp + 30), geo.size.width - 50), y: max(py - 12, 18))
                }
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────
    private var freqTicks: [Float]  { [80, 200, 400, 800, 1600, 3200, 6400] }
    private func freqLabel(_ f: Float) -> String { f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))" }

    private func dbTicks(lo: Float, hi: Float) -> [Float] {
        stride(from: (hi / 10).rounded(.down) * 10,
               through: (lo / 10).rounded(.up) * 10,
               by: -10).map { $0 }
    }

    private func xFrac(_ f: Float) -> Float {
        (log10(max(fMin, min(f, fMax))) - log10(fMin)) / (log10(fMax) - log10(fMin))
    }

    private func yFrac(db: Float, lo: Float, hi: Float) -> Float {
        1 - (max(lo, min(db, hi)) - lo) / (hi - lo)
    }

    private func peakInfo(frame: SpectrumFrame) -> (freq: Float, db: Float)? {
        guard !frame.magsDb.isEmpty,
              let idx = frame.magsDb.indices.max(by: { frame.magsDb[$0] < frame.magsDb[$1] })
        else { return nil }
        return (frame.freqs[idx], frame.magsDb[idx])
    }

    // ── Отрисовка ────────────────────────────────────────────────────
    private func drawLine(ctx: inout GraphicsContext, frame: SpectrumFrame, color: Color,
                          w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat,
                          lo: Float, hi: Float, dash: [CGFloat] = []) {
        guard frame.freqs.count > 2, frame.freqs.count == frame.magsDb.count else { return }
        var path = Path()
        for i in frame.freqs.indices {
            let x = ox + CGFloat(xFrac(frame.freqs[i])) * w
            let y = oy + CGFloat(yFrac(db: frame.magsDb[i], lo: lo, hi: hi)) * h
            i == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y))
        }
        let style = dash.isEmpty ? StrokeStyle(lineWidth: 1.4)
                                 : StrokeStyle(lineWidth: 1.4, dash: dash)
        ctx.stroke(path, with: .color(color), style: style)
    }

    private func drawGrid(ctx: inout GraphicsContext,
                          w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat,
                          lo: Float, hi: Float) {
        for f in freqTicks {
            let x = ox + CGFloat(xFrac(f)) * w
            var p = Path(); p.move(to: .init(x: x, y: oy)); p.addLine(to: .init(x: x, y: oy + h))
            ctx.stroke(p, with: .color(.gray.opacity(0.2)), lineWidth: 0.7)
        }
        for db in dbTicks(lo: lo, hi: hi) {
            let y = oy + CGFloat(yFrac(db: db, lo: lo, hi: hi)) * h
            var p = Path(); p.move(to: .init(x: ox, y: y)); p.addLine(to: .init(x: ox + w, y: y))
            ctx.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 0.7)
        }
        var border = Path(); border.addRect(CGRect(x: ox, y: oy, width: w, height: h))
        ctx.stroke(border, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
    }

    private func drawResonanceZones(ctx: inout GraphicsContext, frame: SpectrumFrame,
                                    w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat) {
        guard frame.magsDb.count > 40 else { return }
        let mags = frame.magsDb; let n = mags.count
        func smooth(_ arr: [Float], _ k: Int) -> [Float] {
            var out = [Float](repeating: 0, count: arr.count)
            for i in 0..<arr.count {
                let lo = max(0, i-k); let hi = min(arr.count-1, i+k)
                out[i] = arr[lo...hi].reduce(0,+) / Float(hi-lo+1)
            }
            return out
        }
        let sm = smooth(mags, 20); let bg = smooth(sm, 100)
        var inZone = false; var zoneStart: Float = 0
        func fillZone(from f0: Float, to f1: Float) {
            let x0 = ox + CGFloat(xFrac(f0)) * w
            let x1 = ox + CGFloat(xFrac(f1)) * w
            var p = Path(); p.addRect(CGRect(x: x0, y: oy, width: max(x1-x0, 1), height: h))
            ctx.fill(p, with: .color(.red.opacity(0.18)))
        }
        for i in 0..<n {
            let hot = (sm[i] - bg[i]) > 5
            if hot && !inZone  { inZone = true;  zoneStart = frame.freqs[i] }
            if !hot && inZone  { inZone = false; fillZone(from: zoneStart, to: frame.freqs[i]) }
        }
        if inZone, let last = frame.freqs.last { fillZone(from: zoneStart, to: last) }
    }
}

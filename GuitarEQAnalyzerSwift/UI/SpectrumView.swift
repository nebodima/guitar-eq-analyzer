import SwiftUI

enum PeakSource { case pre, post }

struct SpectrumView: View {
    let pre:        SpectrumFrame
    let post:       SpectrumFrame
    let snapshot:   SpectrumFrame
    let eqCurve:    SpectrumFrame
    let fMin: Float
    let fMax: Float
    let yMin: Float
    let yMax: Float
    var peakSource: PeakSource = .pre

    var body: some View {
        // yMin/yMax уже сглажены в AudioEngineManager — используем напрямую
        let lo = yMin
        let hi = yMax
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
                    let peakFrame = (peakSource == .post) ? post : pre
                    drawResonanceZones(ctx: &ctx, frame: peakFrame, w: w, h: h, ox: lp, oy: 8)
                    if !snapshot.freqs.isEmpty {
                        drawLine(ctx: &ctx, frame: snapshot, color: .yellow.opacity(0.65),
                                 w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi, dash: [5, 3])
                    }
                    drawLine(ctx: &ctx, frame: pre,  color: .blue.opacity(0.85),
                             w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    drawLine(ctx: &ctx, frame: post, color: .green.opacity(0.95),
                             w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    if !eqCurve.freqs.isEmpty {
                        // Якорим EQ curve на фиксированном уровне нижней четверти экрана
                        // (не зависит от мгновенного сигнала — не скачет)
                        let eqBaseline = lo + (hi - lo) * 0.20
                        let shifted = SpectrumFrame(freqs: eqCurve.freqs,
                                                    magsDb: eqCurve.magsDb.map { $0 + eqBaseline })
                        drawLine(ctx: &ctx, frame: shifted, color: .orange.opacity(0.85),
                                 w: w, h: h, ox: lp, oy: 8, lo: lo, hi: hi)
                    }
                }

                // ── Метки dB ─────────────────────────────────────────
                let ticks = dbTicks(lo: lo, hi: hi)
                ForEach(ticks, id: \.self) { db in
                    let y = 8 + CGFloat(yFrac(db: db, lo: lo, hi: hi)) * h
                    Text("\(Int(db))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: lp - 4, alignment: .trailing)
                        .position(x: (lp - 4) / 2, y: y)
                }

                // ── Метки Hz ─────────────────────────────────────────
                ForEach(freqTicks, id: \.self) { f in
                    let x = lp + CGFloat(xFrac(f)) * w
                    Text(freqLabel(f))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .position(x: x, y: geo.size.height - bp / 2 - 2)
                }

                // ── Легенда ───────────────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    legendRow(.blue,   "Pre-EQ",   dash: [])
                    legendRow(.green,  "Post-EQ",  dash: [])
                    if !eqCurve.freqs.isEmpty {
                        legendRow(.orange, "EQ curve", dash: [])
                    }
                    if !snapshot.freqs.isEmpty {
                        legendRow(.yellow, "Snapshot", dash: [5, 3])
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 12).padding(.leading, lp + 6)

                // ── Idle hint ────────────────────────────────────────
                // Используем post, а не pre — pre может быть пустым при showPreEQ=false
                if post.magsDb.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 36))
                            .foregroundStyle(.gray.opacity(0.45))
                        Text("Click MIC or open a file to start analysis")
                            .font(.body)
                            .foregroundStyle(.gray.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: lp / 2)
                }

                // ── Пик (только метка, без прыгающей вертикали) ──────
                if let pk = peakInfo(frame: post) {
                    let px = lp + CGFloat(xFrac(pk.freq)) * w
                    let py = 8 + CGFloat(yFrac(db: pk.db, lo: lo, hi: hi)) * h
                    Text("\(freqLabel(pk.freq))  \(String(format: "%.0f", pk.db)) dB")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .position(x: min(max(px, lp + 30), geo.size.width - 50), y: max(py - 12, 18))
                }
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    @ViewBuilder
    private func legendRow(_ color: Color, _ label: String, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                let style = dash.isEmpty ? StrokeStyle(lineWidth: 1.5)
                                         : StrokeStyle(lineWidth: 1.5, dash: dash)
                ctx.stroke(p, with: .color(color), style: style)
            }
            .frame(width: 20, height: 10)
            Text(label).foregroundStyle(color)
        }
    }

    private var freqTicks: [Float]  { [80, 200, 400, 800, 1600, 3200, 6400] }
    private func freqLabel(_ f: Float) -> String { f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))" }

    private func dbTicks(lo: Float, hi: Float) -> [Float] {
        // Фиксированные значения — метки не появляются/исчезают резко при адаптации шкалы
        stride(from: Float(0), through: Float(-110), by: Float(-10))
            .filter { $0 >= lo && $0 <= hi }
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
        // 0 dB — отдельная яркая линия-ориентир (если видна)
        if lo <= 0 && 0 <= hi {
            let y0 = oy + CGFloat(yFrac(db: 0, lo: lo, hi: hi)) * h
            var p0 = Path()
            p0.move(to: .init(x: ox, y: y0))
            p0.addLine(to: .init(x: ox + w, y: y0))
            ctx.stroke(p0, with: .color(.gray.opacity(0.55)), lineWidth: 1.0)
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
            // Игнорируем слишком широкие зоны (> 1.5 октавы) — это не резонанс, а характер инструмента
            guard f0 > 0, f1 / f0 < 2.83 else { return }
            let x0 = ox + CGFloat(xFrac(f0)) * w
            let x1 = ox + CGFloat(xFrac(f1)) * w
            var p = Path(); p.addRect(CGRect(x: x0, y: oy, width: max(x1-x0, 1), height: h))
            ctx.fill(p, with: .color(.red.opacity(0.22)))
        }
        for i in 0..<n {
            let hot = (sm[i] - bg[i]) > 8    // порог повышен: 5 → 8 dB
            if hot && !inZone  { inZone = true;  zoneStart = frame.freqs[i] }
            if !hot && inZone  { inZone = false; fillZone(from: zoneStart, to: frame.freqs[i]) }
        }
        if inZone, let last = frame.freqs.last { fillZone(from: zoneStart, to: last) }
    }
}

import SwiftUI

struct SpectrumView: View {
    let pre:      SpectrumFrame
    let post:     SpectrumFrame
    let snapshot: SpectrumFrame
    let eqCurve:  SpectrumFrame   // АЧХ эквалайзера
    let fMin: Float
    let fMax: Float
    let yMin: Float
    let yMax: Float

    var body: some View {
        GeometryReader { geo in
            let leftPad: CGFloat  = 42
            let bottomPad: CGFloat = 20
            let plotW = geo.size.width  - leftPad - 8
            let plotH = geo.size.height - bottomPad - 8

            ZStack(alignment: .topLeading) {
                // ── Фон ──────────────────────────────────────────────
                Color.black.opacity(0.92)

                // ── Canvas: grid + линии ──────────────────────────────
                Canvas { ctx, size in
                    let w = size.width  - leftPad - 8
                    let h = size.height - bottomPad - 8

                    drawGrid(context: &ctx, w: w, h: h, ox: leftPad, oy: 8)

                    // Красные зоны резонансов (pre-EQ)
                    drawResonanceZones(context: &ctx, frame: pre, w: w, h: h, ox: leftPad, oy: 8)

                    if !snapshot.freqs.isEmpty {
                        drawLine(context: &ctx, frame: snapshot, color: .yellow.opacity(0.65),
                                 w: w, h: h, ox: leftPad, oy: 8, dash: [5, 3])
                    }
                    drawLine(context: &ctx, frame: pre,  color: .blue.opacity(0.85),  w: w, h: h, ox: leftPad, oy: 8)
                    drawLine(context: &ctx, frame: post, color: .green.opacity(0.95), w: w, h: h, ox: leftPad, oy: 8)

                    // Кривая EQ (смещена к центру спектра)
                    if !eqCurve.freqs.isEmpty, !pre.magsDb.isEmpty {
                        let offset = pre.magsDb.reduce(0, +) / Float(pre.magsDb.count)
                        let shifted = SpectrumFrame(freqs: eqCurve.freqs,
                                                    magsDb: eqCurve.magsDb.map { $0 + offset })
                        drawLine(context: &ctx, frame: shifted, color: .orange.opacity(0.85),
                                 w: w, h: h, ox: leftPad, oy: 8)
                    }
                }

                // ── Метки dB (левая ось) ─────────────────────────────
                ForEach(dbTicks, id: \.self) { db in
                    let y = 8 + CGFloat(yFrac(db: db)) * plotH
                    Text("\(Int(db))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray.opacity(0.7))
                        .frame(width: leftPad - 4, alignment: .trailing)
                        .position(x: (leftPad - 4) / 2, y: y)
                }

                // ── Метки частот (нижняя ось) ────────────────────────
                ForEach(freqTicks, id: \.self) { f in
                    let x = leftPad + CGFloat(xFrac(freq: f)) * plotW
                    Text(freqLabel(f))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray.opacity(0.7))
                        .position(x: x, y: geo.size.height - bottomPad / 2 - 2)
                }

                // ── Легенда ──────────────────────────────────────────
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
                .padding(.top, 12)
                .padding(.leading, leftPad + 6)

                // ── Пик ─────────────────────────────────────────────
                if let pk = peakInfo(frame: post) {
                    let px = leftPad + CGFloat(xFrac(freq: pk.freq)) * plotW
                    let py = 8 + CGFloat(yFrac(db: pk.db)) * plotH

                    // Вертикальная линия пика
                    Canvas { ctx, _ in
                        var p = Path()
                        p.move(to: CGPoint(x: px, y: 8))
                        p.addLine(to: CGPoint(x: px, y: 8 + plotH))
                        ctx.stroke(p, with: .color(.yellow.opacity(0.35)), lineWidth: 0.8)
                    }

                    Text("\(freqLabel(pk.freq))  \(String(format: "%.0f", pk.db)) dB")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .position(x: min(max(px, leftPad + 30), geo.size.width - 50), y: max(py - 12, 18))
                }
            }
        }
    }

    // ── Вычисление пика ──────────────────────────────────────────────
    private func peakInfo(frame: SpectrumFrame) -> (freq: Float, db: Float)? {
        guard !frame.magsDb.isEmpty else { return nil }
        guard let idx = frame.magsDb.indices.max(by: { frame.magsDb[$0] < frame.magsDb[$1] }) else { return nil }
        return (frame.freqs[idx], frame.magsDb[idx])
    }

    // ── Тики ────────────────────────────────────────────────────────
    private var dbTicks: [Float] { stride(from: yMax, through: yMin, by: -10).map { $0 } }
    private var freqTicks: [Float] { [80, 200, 400, 800, 1600, 3200, 6400] }

    private func freqLabel(_ f: Float) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    // ── Позиции ──────────────────────────────────────────────────────
    private func xFrac(freq: Float) -> Float {
        let f = max(fMin, min(freq, fMax))
        return (log10(f) - log10(fMin)) / (log10(fMax) - log10(fMin))
    }

    private func yFrac(db: Float) -> Float {
        let v = max(yMin, min(db, yMax))
        return 1 - (v - yMin) / (yMax - yMin)
    }

    // ── Отрисовка ────────────────────────────────────────────────────
    private func drawLine(context: inout GraphicsContext,
                          frame: SpectrumFrame, color: Color,
                          w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat,
                          dash: [CGFloat] = []) {
        guard frame.freqs.count > 2, frame.freqs.count == frame.magsDb.count else { return }
        var path = Path()
        for idx in frame.freqs.indices {
            let x = ox + CGFloat(xFrac(freq: frame.freqs[idx])) * w
            let y = oy + CGFloat(yFrac(db: frame.magsDb[idx])) * h
            if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else         { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        var style = StrokeStyle(lineWidth: 1.4)
        if !dash.isEmpty { style = StrokeStyle(lineWidth: 1.4, dash: dash) }
        context.stroke(path, with: .color(color), style: style)
    }

    /// Подсвечивает частоты где спектр выступает >5 dB над локальным фоном
    private func drawResonanceZones(context: inout GraphicsContext,
                                    frame: SpectrumFrame,
                                    w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat) {
        guard frame.magsDb.count > 40 else { return }
        let mags = frame.magsDb
        let n    = mags.count

        // Узкое сглаживание (детали)
        func smooth(_ arr: [Float], _ k: Int) -> [Float] {
            var out = [Float](repeating: 0, count: arr.count)
            for i in 0..<arr.count {
                let lo = max(0, i - k); let hi = min(arr.count - 1, i + k)
                out[i] = arr[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
            return out
        }

        let sm  = smooth(mags, 20)   // ~narrow
        let bg  = smooth(sm, 100)    // ~wide background
        let threshold: Float = 5.0

        var inZone = false
        var zoneStart: Float = 0

        for i in 0..<n {
            let hot = (sm[i] - bg[i]) > threshold
            if hot && !inZone {
                inZone = true
                zoneStart = frame.freqs[i]
            } else if !hot && inZone {
                inZone = false
                let x0 = ox + CGFloat(xFrac(freq: zoneStart)) * w
                let x1 = ox + CGFloat(xFrac(freq: frame.freqs[i])) * w
                var p = Path()
                p.addRect(CGRect(x: x0, y: oy, width: max(x1 - x0, 1), height: h))
                context.fill(p, with: .color(.red.opacity(0.18)))
            }
        }
        if inZone, let last = frame.freqs.last {
            let x0 = ox + CGFloat(xFrac(freq: zoneStart)) * w
            let x1 = ox + CGFloat(xFrac(freq: last)) * w
            var p = Path()
            p.addRect(CGRect(x: x0, y: oy, width: max(x1 - x0, 1), height: h))
            context.fill(p, with: .color(.red.opacity(0.18)))
        }
    }

    private func drawGrid(context: inout GraphicsContext,
                          w: CGFloat, h: CGFloat, ox: CGFloat, oy: CGFloat) {
        for f in freqTicks {
            let x = ox + CGFloat(xFrac(freq: f)) * w
            var p = Path(); p.move(to: CGPoint(x: x, y: oy)); p.addLine(to: CGPoint(x: x, y: oy + h))
            context.stroke(p, with: .color(.gray.opacity(0.2)), lineWidth: 0.7)
        }
        for db in dbTicks {
            let y = oy + CGFloat(yFrac(db: db)) * h
            var p = Path(); p.move(to: CGPoint(x: ox, y: y)); p.addLine(to: CGPoint(x: ox + w, y: y))
            context.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 0.7)
        }
        // Рамка области
        var border = Path()
        border.addRect(CGRect(x: ox, y: oy, width: w, height: h))
        context.stroke(border, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
    }
}

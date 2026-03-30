import SwiftUI

struct SpectrumView: View {
    let pre: SpectrumFrame
    let post: SpectrumFrame
    let fMin: Float
    let fMax: Float
    let yMin: Float
    let yMax: Float

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                drawLine(context: &context, size: size, frame: pre, color: .blue.opacity(0.9))
                drawLine(context: &context, size: size, frame: post, color: .green.opacity(0.95))
            }
            .background(Color.black.opacity(0.92))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original (pre-EQ)").foregroundStyle(.blue)
                    Text("Processed (post-EQ)").foregroundStyle(.green)
                }
                .font(.caption2)
                .padding(8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                Text("Frequency, Hz")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .overlay(alignment: .leading) {
                Text("Amplitude, dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(-90))
                    .padding(8)
            }
        }
    }

    private func drawLine(context: inout GraphicsContext, size: CGSize, frame: SpectrumFrame, color: Color) {
        guard frame.freqs.count > 2, frame.freqs.count == frame.magsDb.count else { return }
        var path = Path()
        for idx in frame.freqs.indices {
            let x = xPos(freq: frame.freqs[idx], width: size.width)
            let y = yPos(db: frame.magsDb[idx], height: size.height)
            if idx == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.4)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let majorFreqs: [Float] = [80, 200, 400, 800, 1600, 3200, 6400]
        for f in majorFreqs {
            let x = xPos(freq: f, width: size.width)
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(p, with: .color(.gray.opacity(0.24)), lineWidth: 0.8)
        }
        let majorDb: [Float] = stride(from: yMax, through: yMin, by: -10).map { $0 }
        for db in majorDb {
            let y = yPos(db: db, height: size.height)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(p, with: .color(.gray.opacity(0.16)), lineWidth: 0.8)
        }
    }

    private func xPos(freq: Float, width: CGFloat) -> CGFloat {
        let f = max(fMin, min(freq, fMax))
        let t = (log10(f) - log10(fMin)) / (log10(fMax) - log10(fMin))
        return CGFloat(t) * width
    }

    private func yPos(db: Float, height: CGFloat) -> CGFloat {
        let value = max(yMin, min(db, yMax))
        let t = (value - yMin) / (yMax - yMin)
        return (1 - CGFloat(t)) * height
    }
}

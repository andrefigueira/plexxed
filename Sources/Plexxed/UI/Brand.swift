import SwiftUI

/// The Plexxed mark: a solid P whose counter is a play triangle. Same geometry as the app icon
/// (scripts/make-icon.swift), with y flipped for SwiftUI.
struct PlexxedMark: View {
    var size: CGFloat = 48
    var color: Color = Theme.textPrimary

    var body: some View {
        Canvas { context, canvas in
            // The letter spans 0.24...0.82 across, so shift it to sit optically centred.
            let rect = CGRect(x: -0.03 * canvas.width, y: 0, width: canvas.width, height: canvas.height)
            for part in Self.letter(in: rect) {
                context.fill(part, with: .color(color))
            }
            context.blendMode = .destinationOut
            context.fill(Self.counter(in: rect), with: .color(.black))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Plexxed")
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    /// Stem and bowl, filled separately so the overlap stays solid.
    static func letter(in rect: CGRect) -> [Path] {
        let u = rect.width
        let stem = Path(
            roundedRect: CGRect(x: rect.minX + 0.24 * u, y: rect.minY + 0.10 * u, width: 0.18 * u, height: 0.80 * u),
            cornerRadius: 0.07 * u
        )
        var bowl = Path()
        bowl.move(to: point(0.33, 0.10, in: rect))
        bowl.addLine(to: point(0.59, 0.10, in: rect))
        bowl.addArc(center: point(0.59, 0.33, in: rect), radius: 0.23 * u,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        bowl.addLine(to: point(0.33, 0.56, in: rect))
        bowl.closeSubpath()
        return [stem, bowl]
    }

    static func counter(in rect: CGRect) -> Path {
        let a = point(0.42, 0.20, in: rect), b = point(0.42, 0.46, in: rect), c = point(0.66, 0.33, in: rect)
        let radius = 0.025 * rect.width
        var path = Path()
        path.move(to: CGPoint(x: a.x, y: (a.y + b.y) / 2))
        path.addArc(tangent1End: b, tangent2End: c, radius: radius)
        path.addArc(tangent1End: c, tangent2End: a, radius: radius)
        path.addArc(tangent1End: a, tangent2End: b, radius: radius)
        path.closeSubpath()
        return path
    }
}

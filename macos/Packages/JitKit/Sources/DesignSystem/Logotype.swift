import SwiftUI

/// The Jit logotype (0.0.3): the word "jit" in one rounded line weight, with the dots of the j and the i drawn
/// as two commits on a lane that runs into the top of the t. Drawn from paths, so it is sharp at any size and
/// follows the appearance; shown on the new-tab page.
public struct JitLogotype: View {
    let height: CGFloat

    public init(height: CGFloat = 56) {
        self.height = height
    }

    /// The drawing's own box; everything below is in these units.
    private static let box = CGSize(width: 108, height: 64)

    public var body: some View {
        let ink = ColorToken.textPrimary.color
        let lane = ColorToken.accentBase.color
        let canvas = ColorToken.surfaceCanvas.color
        Canvas { context, size in
            let scale = size.height / Self.box.height
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)

            // The lane: from the first commit, through the second, into the t.
            var line = Path()
            line.move(to: CGPoint(x: 20, y: 12))
            line.addLine(to: CGPoint(x: 80, y: 12))
            context.stroke(line, with: .color(lane), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var letters = Path()
            // j
            letters.move(to: CGPoint(x: 20, y: 28))
            letters.addLine(to: CGPoint(x: 20, y: 48))
            letters.addQuadCurve(to: CGPoint(x: 9, y: 58), control: CGPoint(x: 20, y: 58))
            // i
            letters.move(to: CGPoint(x: 50, y: 28))
            letters.addLine(to: CGPoint(x: 50, y: 50))
            // t
            letters.move(to: CGPoint(x: 80, y: 12))
            letters.addLine(to: CGPoint(x: 80, y: 41))
            letters.addQuadCurve(to: CGPoint(x: 90, y: 50), control: CGPoint(x: 80, y: 50))
            letters.move(to: CGPoint(x: 70, y: 28))
            letters.addLine(to: CGPoint(x: 92, y: 28))
            context.stroke(letters, with: .color(ink), style: stroke)

            // The commits: a filled one and the open one a branch points at.
            let first = CGRect(x: 14, y: 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: first), with: .color(lane))
            let second = CGRect(x: 44, y: 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: second), with: .color(canvas))
            context.stroke(Path(ellipseIn: second.insetBy(dx: 1.5, dy: 1.5)), with: .color(lane), lineWidth: 3)
        }
        .frame(width: height * Self.box.width / Self.box.height, height: height)
        .accessibilityElement()
        .accessibilityLabel("Jit")
        .accessibilityAddTraits(.isImage)
    }
}

import CoreGraphics
import GitCore

/// Edge paths for one row (P2.13): straight lanes, and lane changes as rounded elbows that meet the node
/// horizontally at the row centre. Every path stays inside `0…height`, so a row draws in isolation.
enum GraphEdgeGeometry {
    /// - Parameters: `x0`/`x1` are the segment's lane centres (already pixel-snapped), `mid` the row centre.
    static func path(x0: CGFloat, x1: CGFloat, half: EdgeSegment.Half, mid: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch half {
        case .full:
            path.move(to: CGPoint(x: x0, y: 0))
            if x0 == x1 {
                path.addLine(to: CGPoint(x: x1, y: height))
            } else {
                // Not produced by the layouter (passing lanes keep their lane); drawn as two elbows anyway.
                let radius = min(mid, height - mid, abs(x1 - x0) / 2)
                path.addArc(
                    tangent1End: CGPoint(x: x0, y: mid), tangent2End: CGPoint(x: x1, y: mid), radius: radius)
                path.addArc(
                    tangent1End: CGPoint(x: x1, y: mid), tangent2End: CGPoint(x: x1, y: height), radius: radius)
                path.addLine(to: CGPoint(x: x1, y: height))
            }
        case .top:
            // Down the source lane, a quarter turn, then horizontally into the node.
            path.move(to: CGPoint(x: x0, y: 0))
            if x0 != x1 {
                let radius = min(mid, abs(x1 - x0))
                path.addArc(
                    tangent1End: CGPoint(x: x0, y: mid), tangent2End: CGPoint(x: x1, y: mid), radius: radius)
            }
            path.addLine(to: CGPoint(x: x1, y: mid))
        case .bottom:
            // Horizontally out of the node, a quarter turn, then down the target lane.
            path.move(to: CGPoint(x: x0, y: mid))
            if x0 != x1 {
                let radius = min(height - mid, abs(x1 - x0))
                path.addArc(
                    tangent1End: CGPoint(x: x1, y: mid), tangent2End: CGPoint(x: x1, y: height), radius: radius)
            }
            path.addLine(to: CGPoint(x: x1, y: height))
        }
        return path
    }
}

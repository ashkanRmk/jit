import SwiftUI

/// One-shot animations only; nothing loops. With Reduce Motion, positional/scale motion and glass
/// morphs become opacity-only at the same duration (see `Motion.reveal`).
public enum MotionToken: String, CaseIterable, Sendable {
    case hover = "motion.hover"
    case press = "motion.press"
    case select = "motion.select"
    case panel = "motion.panel"
    case glassMorph = "motion.glassMorph"
    case feedbackIn = "motion.feedback.in"
    case feedbackOut = "motion.feedback.out"

    public var duration: Double {
        switch self {
        case .hover: 0.10
        case .press: 0.06
        case .select: 0.15
        case .panel: 0.20
        case .glassMorph: 0.22
        case .feedbackIn: 0.18
        case .feedbackOut: 0.12
        }
    }

    public var animation: Animation {
        switch self {
        case .hover, .press, .feedbackIn: .easeOut(duration: duration)
        case .feedbackOut: .easeIn(duration: duration)
        case .select, .panel: .timingCurve(0.2, 0, 0, 1, duration: duration)
        case .glassMorph: .smooth(duration: duration)
        }
    }
}

/// How content enters: a short rise + fade, or fade only with Reduce Motion.
public struct RevealTransition {
    public static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Space.s2))
    }
}

// Prints the CGWindowID of the frontmost on-screen window owned by the process with the given pid.
// usage: swift window-id.swift <pid> [title-substring] [--bounds]
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid> [title]\n".utf8))
    exit(2)
}
// `--bounds` as the last argument prints "x,y,width,height" (screen points) instead of the id.
let printsBounds = arguments.last == "--bounds"
let title = arguments.count > 2 && arguments[2] != "--bounds" ? arguments[2] : nil
var windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
if printsBounds {
    // The largest window of the process (the main window, not a child panel above it).
    func area(_ window: [String: Any]) -> CGFloat {
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    windows.sort { area($0) > area($1) }
}
for window in windows {
    guard window[kCGWindowOwnerPID as String] as? Int == pid, window[kCGWindowLayer as String] as? Int == 0
    else { continue }
    if let title, !((window[kCGWindowName as String] as? String) ?? "").contains(title) { continue }
    if printsBounds, let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
        print("\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)),\(Int(bounds["Width"] ?? 0)),\(Int(bounds["Height"] ?? 0))")
        exit(0)
    }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)

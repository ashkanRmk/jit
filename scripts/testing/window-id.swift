// Prints the CGWindowID of the frontmost on-screen window owned by the process with the given pid.
// usage: swift window-id.swift <pid> [title-substring]
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid> [title]\n".utf8))
    exit(2)
}
let title = arguments.count > 2 ? arguments[2] : nil
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
for window in windows {
    guard window[kCGWindowOwnerPID as String] as? Int == pid, window[kCGWindowLayer as String] as? Int == 0
    else { continue }
    if let title, !((window[kCGWindowName as String] as? String) ?? "").contains(title) { continue }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)

import AppKit
import DesignSystem
import Services
import SwiftUI

/// SSH key passphrase (design §3.5): a standard sheet on the main window, triggered by the helper's askpass
/// request through the broker. "Remember in Keychain" is off by default. Cancel fails the operation.
struct PassphraseSheet: View {
    let keyPath: String
    let fingerprint: String?
    let finish: (SecretBytes?, Bool) -> Void
    @State private var passphrase = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .top, spacing: Space.s5) {
                Image(systemName: "key.fill")
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.token(.accentBase))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Enter the passphrase for “\((keyPath as NSString).lastPathComponent)”")
                        .typeStyle(.headline)
                    Text((keyPath as NSString).abbreviatingWithTildeInPath)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.secondary)
                    if let fingerprint {
                        Text(fingerprint).typeStyle(.monoCaption).foregroundStyle(.secondary)
                    }
                }
            }
            SecureField("Passphrase", text: $passphrase)
                .onSubmit(submit)
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil, false) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(Space.s8)
        .frame(width: 460)
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        let secret = SecretBytes(utf8: passphrase)
        passphrase = ""
        finish(secret, remember)
    }
}

@MainActor
enum PassphrasePresenter {
    /// Shows the sheet on `window` and returns the answer (nil = cancelled). Waits if another sheet is open.
    static func ask(on window: NSWindow?, keyPath: String, fingerprint: String?) async -> (SecretBytes, remember: Bool)?
    {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 220), styleMask: [.titled], backing: .buffered,
                defer: true)
            var resumed = false
            let host = NSHostingController(
                rootView: PassphraseSheet(keyPath: keyPath, fingerprint: fingerprint) {
                    [weak window, weak sheet] secret, remember in
                    if let window, let sheet { window.endSheet(sheet) }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: secret.map { ($0, remember) })
                })
            host.sizingOptions = .preferredContentSize
            sheet.contentViewController = host
            window.beginCriticalSheet(sheet)
        }
    }
}

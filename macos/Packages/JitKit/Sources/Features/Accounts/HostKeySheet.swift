import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// Unknown SSH host key verification (design §3.5, ADR-0036): scans the host's keys with `ssh-keyscan`, shows the
/// SHA-256 fingerprints, compares them with the provider's published values for github.com, and writes only Jit's
/// own known_hosts after an explicit "Trust This Host". A key that differs from one already trusted is a hard
/// security error with no trust option.
@MainActor @Observable
final class HostKeyModel {
    enum Phase: Equatable {
        case scanning
        case ready
        case changed
        case failed(String)
        case trusted
    }

    let target: HostKeyTarget
    private(set) var phase: Phase = .scanning
    private(set) var keys: [SSHHostKey] = []
    /// Fingerprints the provider publishes (github.com only; empty = no comparison available).
    private(set) var published: [String] = []
    @ObservationIgnored let knownHosts: KnownHostsStore
    @ObservationIgnored let publishedFingerprints: @Sendable (String) async -> [String]

    init(
        target: HostKeyTarget, knownHosts: KnownHostsStore,
        publishedFingerprints: @escaping @Sendable (String) async -> [String] = { _ in [] }
    ) {
        self.target = target
        self.knownHosts = knownHosts
        self.publishedFingerprints = publishedFingerprints
    }

    func load() async {
        let found = await SSHTools.scanHostKeys(host: target.host, port: target.port)
        guard !found.isEmpty else {
            phase = .failed(
                "Jit couldn't read \(target.host)'s host key. Check the host name and port, and your connection or VPN."
            )
            return
        }
        keys = found
        let trusted = knownHosts.entries(host: target.host, port: target.port)
        if trusted.contains(where: { entry in found.contains { $0.type == entry.type && $0.key != entry.key } }) {
            phase = .changed
            return
        }
        phase = .ready
        published = await publishedFingerprints(target.host)
    }

    /// The preferred key: ED25519, then ECDSA, then RSA.
    var primary: SSHHostKey? {
        keys.first { $0.displayType == "ED25519" } ?? keys.first { $0.displayType == "ECDSA" } ?? keys.first
    }

    enum Comparison { case matches, mismatch, unavailable }

    var comparison: Comparison {
        guard let primary, !published.isEmpty else { return .unavailable }
        return published.contains(primary.fingerprint) ? .matches : .mismatch
    }

    func trust() {
        guard let primary, comparison != .mismatch else { return }
        do {
            try knownHosts.trust(primary)
            phase = .trusted
        } catch KnownHostsError.changedKey {
            phase = .changed
        } catch {
            phase = .failed("Jit couldn't write its known_hosts file.")
        }
    }
}

struct HostKeySheet: View {
    @State var model: HostKeyModel
    let dismiss: () -> Void
    let trusted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            switch model.phase {
            case .changed:
                changed
            default:
                verify
            }
        }
        .padding(Space.s8)
        .frame(width: 520)
        .task { await model.load() }
    }

    private var hostLabel: String {
        model.target.port == 22 ? model.target.host : "\(model.target.host):\(model.target.port)"
    }

    @ViewBuilder private var verify: some View {
        HStack(alignment: .top, spacing: Space.s5) {
            Image(systemName: "key.viewfinder")
                .symbolSize(IconSize.lg)
                .foregroundStyle(.token(.accentBase))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Verify the SSH host \(hostLabel)")
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                Text(
                    "Jit hasn't connected to this server before. Compare the fingerprint with the one your administrator or provider publishes before trusting it."
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        switch model.phase {
        case .scanning:
            HStack(spacing: Space.s3) {
                ProgressView().controlSize(.small)
                Text("Reading the host key…").typeStyle(.callout).foregroundStyle(.token(.textSecondary))
            }
        case .failed(let message):
            Text(message).typeStyle(.callout).foregroundStyle(.token(.statusDanger))
        case .ready, .trusted, .changed:
            if let key = model.primary {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("\(key.displayType) key fingerprint (SHA-256)")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                    Text(key.fingerprint)
                        .typeStyle(.monoTitle)
                        .foregroundStyle(.token(.textPrimary))
                        .textSelection(.enabled)
                        .accessibilityLabel("Fingerprint \(key.fingerprint)")
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
                comparisonLine
            }
        }
        if model.phase == .trusted {
            Label(
                "Trusted. Saved to Jit's own known_hosts file — your ~/.ssh files were not changed.",
                systemImage: "checkmark.circle.fill"
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.statusSuccess))
        }
        HStack {
            Spacer()
            if model.phase == .trusted {
                Button("Retry Operation") { trusted() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Trust This Host") { model.trust() }
                    .disabled(model.phase != .ready || model.comparison == .mismatch)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var comparisonLine: some View {
        switch model.comparison {
        case .matches:
            Label("Matches the fingerprint GitHub publishes.", systemImage: "checkmark.seal.fill")
                .typeStyle(.callout)
                .foregroundStyle(.token(.statusSuccess))
        case .mismatch:
            Label(
                "Does NOT match the fingerprint the provider publishes. Don't trust this host.",
                systemImage: "xmark.octagon.fill"
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.statusDanger))
        case .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder private var changed: some View {
        HStack(alignment: .top, spacing: Space.s5) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .symbolSize(IconSize.lg)
                .foregroundStyle(.token(.statusDanger))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("The host key of \(hostLabel) has changed")
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                Text(
                    "This may indicate an attack — someone intercepting the connection — or the server was reinstalled. Jit won't connect. Ask the server's administrator for the new fingerprint; once verified, remove the old entry from Jit's known_hosts file (~/Library/Application Support/Jit/known_hosts) and connect again."
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }
}

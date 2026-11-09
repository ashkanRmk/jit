import AppKit
import DesignSystem
import Observation
import Services
import SwiftUI

/// Drives one diagnostics run (design §3.7). Nothing runs until `start` — no polling, no timers.
@MainActor @Observable
final class DiagnosticsModel {
    private(set) var steps = DiagnosticStep.allPending
    private(set) var isRunning = false
    private(set) var hasRun = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(instance: ProviderInstance, account: HostingAccount?, accounts: AccountsService) {
        task?.cancel()
        steps = DiagnosticStep.allPending
        isRunning = true
        hasRun = true
        task = Task { [weak self] in
            let runner = await accounts.diagnosticsRunner(for: instance, account: account)
            for await step in runner.run() {
                guard let self else { return }
                self.apply(step)
            }
            self?.isRunning = false
        }
    }

    func apply(_ step: DiagnosticStep) {
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
        steps[index] = step
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func reset() {
        cancel()
        steps = DiagnosticStep.allPending
        hasRun = false
    }
}

/// Connectivity diagnostics for one server: an opaque step list (content — it's read carefully and copied) with
/// standard "Test Connection" and "Copy Report" buttons. Embedded in Settings ▸ Servers & Network.
public struct DiagnosticsView: View {
    let instance: ProviderInstance
    let account: HostingAccount?
    let accounts: AccountsService
    @State private var model = DiagnosticsModel()

    public init(instance: ProviderInstance, account: HostingAccount?, accounts: AccountsService) {
        self.instance = instance
        self.account = account
        self.accounts = accounts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(ColorToken.borderSubtle.color)
                            .frame(height: Border.hairline)
                            .accessibilityHidden(true)
                    }
                    DiagnosticStepRow(step: step)
                }
            }
            .background(ColorToken.surfaceRaised.color, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connection test steps")
            HStack(spacing: Space.s4) {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Testing \(instance.name)…")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                }
                Spacer()
                Button("Copy Report", action: copyReport)
                    .disabled(!model.hasRun || model.isRunning)
                if model.isRunning {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Test Connection") {
                        model.start(instance: instance, account: account, accounts: accounts)
                    }
                }
            }
        }
        .onChange(of: instance) { model.reset() }
        .onChange(of: account) { model.reset() }
        .onDisappear { model.cancel() }
    }

    private func copyReport() {
        let text = DiagnosticsReport.text(instance: instance, account: account, steps: model.steps)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct DiagnosticStepRow: View {
    let step: DiagnosticStep

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            icon
                .frame(width: IconSize.md, height: IconSize.md)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(step.title)
                    .typeStyle(.headline)
                    .foregroundStyle(.token(step.status == .pending ? .textSecondary : .textPrimary))
                Text(step.result)
                    .typeStyle(.callout)
                    .foregroundStyle(.token(resultColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(step.details, id: \.self) { detail in
                    Text(detail)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let explanation = step.explanation {
                    Text(explanation)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(step.title): \(step.status.title).", step.result]
        parts.append(contentsOf: step.details)
        if let explanation = step.explanation { parts.append(explanation) }
        return parts.joined(separator: " ")
    }

    private var resultColor: ColorToken {
        switch step.status {
        case .failed: .statusDanger
        case .pending, .skipped: .textTertiary
        default: .textPrimary
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle.dashed")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textTertiary))
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.statusSuccess))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.statusWarning))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.statusDanger))
        case .skipped:
            Image(systemName: "minus.circle")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textTertiary))
        }
    }
}

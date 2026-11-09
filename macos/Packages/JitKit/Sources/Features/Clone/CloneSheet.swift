import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// Clone from URL (design §3.5): validation, destination, derived name, progress, cancel, retry. Runs with the
/// non-interactive environment; cancelling removes the partial folder (or empties a pre-existing empty one).
@MainActor @Observable
final class CloneModel {
    enum Phase: Equatable {
        case editing
        case running
        case failed(PresentableError)
    }

    var url = "" {
        didSet {
            if !nameEdited { name = url.isEmpty ? "" : CloneURL.derivedName(url) }
            allowInsecure = false
        }
    }
    var name = ""
    var nameEdited = false
    var parent: String
    var allowInsecure = false
    private(set) var phase: Phase = .editing
    private(set) var progress: OperationProgress?
    private(set) var submoduleNote = false
    @ObservationIgnored var finish: (String?) -> Void = { _ in }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let engine: GitEngine
    @ObservationIgnored private let preferences: PreferencesStore
    /// Captures the active profile snapshot when Clone is pressed (credentials, SSH key, CA, proxy).
    @ObservationIgnored private let makeContext: @MainActor () -> ExecContext

    init(
        engine: GitEngine, preferences: PreferencesStore, url: String = "",
        makeContext: @escaping @MainActor () -> ExecContext = { .anonymous }
    ) {
        self.engine = engine
        self.preferences = preferences
        self.makeContext = makeContext
        parent = preferences.cloneParentDirectory
        if !url.isEmpty {
            self.url = url
            name = CloneURL.derivedName(url)
        }
    }

    var kind: Result<CloneURL.Kind, GitCoreError> { CloneURL.classify(url) }

    var urlProblem: String? {
        guard !url.isEmpty else { return nil }
        if case .failure(let error) = kind { return error.summary }
        return nil
    }

    var isInsecure: Bool { (try? kind.get()) == .insecureHTTP }

    var destinationProblem: String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") || name.hasPrefix("-") || name == "." || name == ".." {
            return "Choose another folder name."
        }
        let path = (parent as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return "A file named “\(name)” already exists there." }
            if !((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty {
                return "“\(name)” already exists and isn't empty."
            }
        }
        return nil
    }

    var iCloudWarning: Bool {
        parent.contains("/Library/Mobile Documents/") || parent.hasSuffix("/Desktop")
            || parent.hasSuffix("/Documents")
                && FileManager.default.fileExists(
                    atPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Documents")
    }

    var canClone: Bool {
        phase != .running && !url.isEmpty && !name.isEmpty && urlProblem == nil && destinationProblem == nil
            && (!isInsecure || allowInsecure)
    }

    func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }

    func start() {
        guard canClone else { return }
        preferences.cloneParentDirectory = parent
        phase = .running
        progress = nil
        let request = CloneRequest(url: url, parentDirectory: parent, name: name, allowInsecureHTTP: allowInsecure)
        let (stream, continuation) = AsyncStream.makeStream(
            of: OperationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { [weak self] in
            for await value in stream { self?.progress = value }
        }
        let engine = engine
        let context = makeContext()
        task = Task {
            let result: Result<CloneOutcome, GitCoreError>
            do throws(GitCoreError) {
                result = .success(
                    try await cloneRepository(request, engine: engine, context: context, progress: continuation))
            } catch {
                result = .failure(error)
            }
            continuation.finish()
            await progressTask.value
            switch result {
            case .success(let outcome):
                if outcome.hasSubmodules {
                    submoduleNote = true
                    let alert = NSAlert()
                    alert.messageText = "This repository uses submodules."
                    alert.informativeText =
                        "Jit cloned the main repository only. Run “git submodule update --init” in Terminal if you need them (submodule support is planned)."
                    alert.runModal()
                }
                finish(outcome.path)
            case .failure(.cancelled):
                phase = .editing
            case .failure(let error):
                phase = .failed(PresentableError.make(error))
            }
        }
    }

    func cancel() {
        if phase == .running {
            task?.cancel()
        } else {
            finish(nil)
        }
    }
}

struct CloneSheet: View {
    @Bindable var model: CloneModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            Text("Clone Repository").typeStyle(.headline)
            VStack(alignment: .leading, spacing: Space.s3) {
                TextField(
                    text: $model.url,
                    prompt: Text(verbatim: "https://github.com/owner/repo.git or git@host:owner/repo.git")
                ) {
                    Text("Repository URL")
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.phase == .running)
                .onSubmit(model.start)
                if let problem = model.urlProblem {
                    Text(problem).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                }
                if model.isInsecure {
                    Toggle(
                        "Clone over unencrypted HTTP (anyone on the network can read or alter it)",
                        isOn: $model.allowInsecure
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.statusWarning))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Space.s5, verticalSpacing: Space.s4) {
                GridRow {
                    Text("Where").typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                    HStack {
                        Text((model.parent as NSString).abbreviatingWithTildeInPath)
                            .typeStyle(.monoCaption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: model.chooseParent)
                            .disabled(model.phase == .running)
                    }
                }
                GridRow {
                    Text("Folder").typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                    TextField(
                        "Folder name",
                        text: Binding(
                            get: { model.name },
                            set: {
                                model.name = $0; model.nameEdited = true
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.phase == .running)
                }
            }
            if let problem = model.destinationProblem {
                Text(problem).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
            } else if model.iCloudWarning {
                Label(
                    "This folder may sync to iCloud Drive, which can corrupt Git repositories.", systemImage: "icloud"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusWarning))
            }
            switch model.phase {
            case .running:
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let fraction = model.progress?.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(model.progress?.summary ?? "Connecting…")
                        Spacer()
                        if let rate = model.progress?.rate { Text(rate).monospacedDigit() }
                    }
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cloning")
                .accessibilityValue(model.progress?.summary ?? "Connecting")
            case .failed(let error):
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(error.title).typeStyle(.callout).foregroundStyle(.token(.statusDanger))
                    Text(error.explanation).typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = error.technicalDetail {
                        Text(DisplayText.sanitize(detail, keepNewlines: true))
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textTertiary))
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            case .editing:
                Text("Public HTTPS and SSH keys loaded in ssh-agent work without setup. Submodules aren't cloned.")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                Button(failed ? "Retry" : "Clone", action: model.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canClone)
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: 520)
    }

    private var failed: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}

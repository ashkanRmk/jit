import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings ▸ Git (Phase 7 design §3.3, ADR-0019): which Git Jit runs, a validated custom Git, a reset to the
/// bundled Git, and — only when no usable Git exists and the developer tools are absent — an explicit
/// "Install Command Line Tools" button. Nothing here runs `/usr/bin/git` or `xcode-select --install` unless the
/// user clicks for it.
struct GitSettingsView: View {
    @Bindable var preferences: PreferencesStore
    let engine: GitEngine

    enum Status: Equatable {
        case checking
        case ready(GitExecutable)
        case failed(GitCoreError)
    }

    @State private var status: Status = .checking
    @State private var validating = false
    @State private var choiceError: String?
    @State private var refreshToken = 0

    var body: some View {
        Form {
            Section {
                switch status {
                case .checking:
                    HStack(spacing: Space.s3) {
                        ProgressView().controlSize(.small)
                        Text("Checking Git…").typeStyle(.callout).foregroundStyle(.secondary)
                    }
                case .ready(let git):
                    LabeledContent("Version", value: git.version.displayString)
                    LabeledContent("Source", value: git.source.rawValue)
                    LabeledContent("Location") {
                        Text(git.path)
                            .typeStyle(.monoCaption)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                case .failed(let error):
                    Label {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(error.summary).typeStyle(.headline)
                            if let detail = error.detail {
                                Text(detail).typeStyle(.monoCaption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.token(.statusDanger))
                    }
                }
            } header: {
                Text("Git in use")
            }
            Section {
                HStack(spacing: Space.s4) {
                    Button("Choose Git…", action: chooseGit)
                        .disabled(validating)
                    if preferences.customGitPath != nil {
                        Button("Use Bundled Git") { apply(nil) }
                            .disabled(validating)
                    }
                    if validating { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let choiceError {
                    Text(choiceError)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.statusDanger))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Custom Git")
            } footer: {
                Text(
                    "Jit runs the Git that comes with it unless you choose another one here. Git \(GitVersion.minimum.displayString) or newer is required. Your ~/.gitconfig and each repository's settings apply either way."
                )
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
            }
            if case .failed = status, developerToolsMissing {
                Section {
                    Text(
                        "Apple's Command Line Tools include Git. Installing them opens a system dialog and downloads from Apple."
                    )
                    .typeStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Install Command Line Tools…", action: installCommandLineTools)
                        Spacer()
                    }
                } header: {
                    Text("Command Line Tools")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: refreshToken) { await refresh() }
    }

    private var developerToolsMissing: Bool {
        GitLocator(configuration: .init(allowsEnvironmentOverride: false)).developerToolsGit() == nil
    }

    private func refresh() async {
        status = .checking
        do throws(GitCoreError) {
            status = .ready(try await engine.gitInfo())
        } catch {
            status = .failed(error)
        }
    }

    private func chooseGit() {
        let panel = NSOpenPanel()
        panel.title = "Choose Git"
        panel.message = "Choose a git executable, for example /opt/homebrew/bin/git."
        panel.prompt = "Use This Git"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validate(url.path)
    }

    private func validate(_ path: String) {
        validating = true
        choiceError = nil
        Task {
            defer { validating = false }
            do throws(GitCoreError) {
                _ = try await engine.validateGit(at: path)
                apply(path)
            } catch {
                choiceError = "Jit can't use the Git at \(path): \(error.summary)"
            }
        }
    }

    private func apply(_ path: String?) {
        choiceError = nil
        preferences.customGitPath = path
        Task {
            await engine.setUserGitPath(path)
            refreshToken += 1
        }
    }

    /// Only on an explicit click: asks macOS to show its Command Line Tools installer.
    private func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        do {
            try process.run()
        } catch {
            choiceError = "Couldn't start the installer: \(error.localizedDescription)"
        }
    }
}

import Foundation
import GitCore
import Observation

/// State of the Phase 0 foundation window. Replaced by the real repository session in Phase 1.
@MainActor @Observable
public final class FoundationModel {
    public enum State: Equatable {
        case empty
        /// `showsIndicator` turns true only after 150 ms, so fast discoveries never flash a spinner.
        case loading(URL, showsIndicator: Bool)
        case loaded(RepositoryInfo, git: GitExecutable)
        case failed(URL?, GitCoreError)
    }

    public private(set) var state: State = .empty
    public var isImporterPresented = false

    private let engine: GitEngine
    private var discovery: Task<Void, Never>?
    private var indicator: Task<Void, Never>?

    public init(engine: GitEngine) {
        self.engine = engine
    }

    public func presentOpenPanel() {
        isImporterPresented = true
    }

    /// Discovers the repository at `url`, cancelling any discovery still running.
    public func open(_ url: URL) {
        discovery?.cancel()
        indicator?.cancel()
        state = .loading(url, showsIndicator: false)
        indicator = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, case .loading(url, false) = self.state else { return }
            self.state = .loading(url, showsIndicator: true)
        }
        discovery = Task { [engine] in
            defer { if !Task.isCancelled { self.indicator?.cancel() } }
            do throws(GitCoreError) {
                let git = try await engine.gitInfo()
                let info = try await engine.discoverRepository(at: url)
                guard !Task.isCancelled else { return }
                state = .loaded(info, git: git)
            } catch .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(url, error)
            }
        }
    }

    /// Stops any running discovery (window closing).
    public func cancel() {
        discovery?.cancel()
        discovery = nil
        indicator?.cancel()
        indicator = nil
        if case .loading = state { state = .empty }
    }

    public func importFailed(_ error: any Error) {
        state = .failed(nil, .io(summary: error.localizedDescription))
    }
}

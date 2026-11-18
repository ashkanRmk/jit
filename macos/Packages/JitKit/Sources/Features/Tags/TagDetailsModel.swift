import GitCore
import Observation

@MainActor @Observable
final class TagDetailsModel {
    private(set) var tag: TagDetails?
    private(set) var expected: RepoStateToken?
    private(set) var remotes: [String] = []
    private(set) var error: String?
    var remote = ""
    @ObservationIgnored private var readTask: Task<Result<Loaded, GitCoreError>, Never>?
    private struct Loaded: Sendable {
        let tag: TagDetails
        let remotes: [String]
        let state: RepoStateToken
    }

    func cancel() { readTask?.cancel(); readTask = nil }

    func load(repository: RepositoryHandle, ref: GitRef, format: ObjectFormat, refresh: Bool = false) async {
        cancel()
        guard !Task.isCancelled else { return }
        tag = nil; error = nil; expected = nil
        let task = Task { () -> Result<Loaded, GitCoreError> in
            do throws(GitCoreError) {
                let current: GitRef
                if refresh {
                    guard let value = try await repository.refs().ref(named: ref.fullName), value.kind == .tag else {
                        throw .refused(summary: "The tag no longer exists. Close these details and refresh the tags.")
                    }
                    current = value
                } else {
                    current = ref
                }
                let details = try await repository.tagDetails(
                    named: current.shortName, object: current.object.hex(format))
                let remotes = try await repository.remotes().map(\.name)
                let state = try await repository.captureState()
                return .success(Loaded(tag: details, remotes: remotes, state: state))
            } catch { return .failure(error) }
        }
        readTask = task
        let result = await task.value
        guard !Task.isCancelled, !task.isCancelled else { return }
        readTask = nil
        switch result {
        case .success(let value):
            remotes = value.remotes
            remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first ?? ""
            expected = value.state; tag = value.tag
        case .failure(let error): self.error = error.summary
        }
    }
}

import DesignSystem
import GitCore
import SwiftUI

struct NewTagSheet: View {
    let controller: OperationsController
    let commit: String
    let label: String
    @State private var annotated: Bool
    let remotes: [String]
    let expected: RepoStateToken
    @State private var name = ""
    @State private var message = ""
    @State private var push = false
    @State private var remote = ""
    @State private var validation: String?
    @State private var valid = false
    @State private var submitting = false
    @FocusState private var focused: Bool

    init(
        controller: OperationsController, commit: String, label: String, annotated: Bool, remotes: [String],
        expected: RepoStateToken
    ) {
        self.controller = controller; self.commit = commit; self.label = label; self.remotes = remotes;
        self.expected = expected
        _annotated = State(initialValue: annotated)
    }

    var body: some View {
        SheetScaffold(
            title: annotated ? "Create Annotated Tag" : "Create Tag", subtitle: "At \(label) · \(commit.prefix(7))"
        ) {
            VStack(alignment: .leading, spacing: Space.s4) {
                TextField("Tag name", text: $name).focused($focused)
                Toggle("Annotated tag", isOn: $annotated)
                if annotated {
                    Text("Tag message").typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                    TextEditor(text: $message)
                        .typeStyle(.body)
                        .accessibilityLabel("Tag message")
                        .scrollContentBackground(.hidden)
                        .padding(Space.s2)
                        .frame(height: Space.s8 * 4)
                        .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(
                                ColorToken.borderSubtle.color, lineWidth: Border.hairline))
                }
                if let validation { Text(validation).foregroundStyle(.token(.statusDanger)).typeStyle(.caption) }
                Toggle("Push tag after creation", isOn: $push).disabled(remotes.isEmpty)
                if push, !remotes.isEmpty {
                    Picker("Remote", selection: $remote) {
                        ForEach(remotes, id: \.self) { Text($0).tag($0) }
                    }
                }
                if remotes.isEmpty {
                    Text("No remotes configured. The tag will be created locally.").typeStyle(.caption)
                }
                if annotated { IdentityLine(controller: controller) }
            }
        } buttons: {
            Button("Cancel", action: controller.cancelSheet).keyboardShortcut(.cancelAction)
            Button("Create Tag") {
                guard canCreate else { return }
                submitting = true
                controller.model.preferences.pushTagsAfterCreation = push
                controller.cancelSheet()
                controller.createTag(
                    name, at: commit, message: annotated ? message : nil,
                    remote: push ? remote : nil, expected: expected)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .help("Create Tag (⌘Return)")
            .disabled(!canCreate)
        }
        .onAppear {
            push = controller.model.preferences.pushTagsAfterCreation && !remotes.isEmpty
            remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first ?? ""
            focused = true
        }
        .task(id: name) {
            valid = false
            guard !name.isEmpty, let repository = controller.session.repository else { validation = nil; return }
            do {
                try await repository.validateTagName(name)
                guard !Task.isCancelled else { return }
                validation = nil
                valid = true
            } catch let error as GitCoreError {
                guard !Task.isCancelled else { return }
                validation = error.summary
            } catch {
                validation = "Couldn’t validate this tag name."
            }
        }
    }

    private var canCreate: Bool {
        valid && !submitting && !controller.session.isBusy
            && (!annotated || controller.hasProfile && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!push || !remote.isEmpty)
    }

}

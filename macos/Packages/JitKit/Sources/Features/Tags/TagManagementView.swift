import DesignSystem
import GitCore
import SwiftUI

struct TagManagementView: View {
    let controller: OperationsController
    let ref: GitRef
    let dismiss: () -> Void
    @State var model = TagDetailsModel()
    @State private var generation = 0

    var body: some View {
        SheetScaffold(title: "Tag \(ref.shortName)", subtitle: controller.repositoryName, width: 440) {
            if let tag = model.tag {
                TagDetailsContent(tag: tag)
                if !model.remotes.isEmpty {
                    Picker("Remote", selection: $model.remote) {
                        ForEach(model.remotes, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Button("Push Tag") {
                            guard let expected = model.expected else { return }
                            dismiss(); controller.pushTag(tag, remote: model.remote, expected: expected)
                        }
                        Button("Delete from Remote…", role: .destructive) {
                            dismiss(); controller.sheet = .remoteTagDelete(name: tag.name, remote: model.remote)
                        }
                    }
                    .disabled(controller.session.isBusy || model.remote.isEmpty)
                } else {
                    Text("No remotes configured. Add a remote to push or delete a remote tag.")
                        .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                }
            } else if let error = model.error {
                Text(error).typeStyle(.callout).foregroundStyle(.token(.statusDanger))
                Button("Refresh Details") { generation += 1 }
            } else {
                ProgressView("Reading tag…")
            }
        } buttons: {
            if model.tag != nil {
                Button("Refresh") { generation += 1 }
                Button("Delete Local Tag…", role: .destructive) {
                    guard let tag = model.tag, let expected = model.expected else { return }
                    dismiss(); controller.confirmLocalTagDeletion(tag, expected: expected)
                }.disabled(controller.session.isBusy)
            }
            Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
        }
        .task(id: generation) {
            guard let repository = controller.session.repository else { return }
            if generation == 0, model.tag != nil { return }
            await model.load(
                repository: repository, ref: ref, format: controller.refs?.format ?? .sha1, refresh: generation > 0)
        }
        .onDisappear { model.cancel() }
        .onExitCommand(perform: dismiss)
    }
}

struct TagDetailsContent: View {
    let tag: TagDetails
    @State private var messageHeight: CGFloat = Space.s6

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Label(
                tag.isAnnotated ? "Annotated tag" : "Lightweight tag", systemImage: tag.isAnnotated ? "tag.fill" : "tag"
            )
            .typeStyle(.callout).foregroundStyle(.token(.textPrimary))
            value("Tag object", tag.objectOID)
            value("Target (\(tag.targetType))", tag.targetOID)
            if let tagger = tag.tagger {
                Text(DisplayText.sanitize(String(tagger.prefix(512)))).lineLimit(2).typeStyle(.callout).foregroundStyle(
                    .token(.textPrimary))
            }
            if let date = tag.date {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            }
            if tag.isAnnotated {
                ScrollView {
                    Text(
                        tag.message.isEmpty
                            ? "(empty annotation)"
                            : DisplayText.sanitize(String(tag.message.prefix(16_384)), keepNewlines: true)
                    )
                    .typeStyle(.body).foregroundStyle(.token(.textPrimary))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        messageHeight = $0
                    }
                }
                .frame(height: min(messageHeight, 180))
                .padding(Space.s4)
                .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
                if tag.message.count > 16_384 {
                    HStack {
                        Text("Annotation preview truncated.").typeStyle(.caption).foregroundStyle(
                            .token(.textSecondary))
                        Button("Copy Full Message") { Pasteboard.copy(tag.message) }
                    }
                }
            }
        }
    }

    private func value(_ title: String, _ oid: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).typeStyle(.caption).foregroundStyle(.token(.textTertiary))
                Text(oid).typeStyle(.monoCaption).foregroundStyle(.token(.textPrimary))
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.s2)
            Button("Copy") { Pasteboard.copy(oid) }.controlSize(.small).help("Copy \(title.lowercased()) SHA")
        }
    }
}

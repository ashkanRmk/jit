import DesignSystem
import GitCore
import SwiftUI

struct MarkdownPreviewDocument: Sendable {
    struct Block: Identifiable, Sendable {
        let id: Int
        let kind: PresentationIntent.Kind
        let text: AttributedString
        var children: [Block] = []
    }

    enum LoadingState {
        case loading
        case ready(MarkdownPreviewDocument)
        case failed(String)
    }

    let blocks: [Block]

    @concurrent static func load(from repository: RepositoryHandle, target: DiffTarget, path: String) async throws
        -> Self
    {
        let bytes = try await repository.diffFileContent(target, path: path, limit: 1024 * 1024)
        try Task.checkCancellation()
        guard !bytes.contains(0), let source = String(bytes: bytes, encoding: .utf8) else {
            throw GitCoreError.refused(summary: "Markdown preview requires a UTF-8 text file.")
        }
        return try Self(markdown: source)
    }

    init(markdown: String) throws {
        var text = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        // Keep image descriptions as text and make only web links interactive.
        for run in text.runs {
            if run.imageURL != nil { text[run.range].imageURL = nil }
            if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                text[run.range].link = nil
            }
        }
        let leaves = text.runs[\.presentationIntent].map { intent, range in
            (path: Array((intent?.components ?? []).reversed()), text: AttributedString(text[range]))
        }
        var index = 0
        func collect(depth: Int, parent: Int?) -> [Block] {
            var blocks: [Block] = []
            while index < leaves.count {
                let leaf = leaves[index]
                if let parent,
                    !leaf.path.indices.contains(depth - 1) || leaf.path[depth - 1].identity != parent
                {
                    break
                }
                guard leaf.path.indices.contains(depth) else {
                    blocks.append(Block(id: -index - 1, kind: .paragraph, text: leaf.text))
                    index += 1
                    continue
                }
                let component = leaf.path[depth]
                if leaf.path.count > depth + 1 {
                    let children = collect(depth: depth + 1, parent: component.identity)
                    blocks.append(Block(id: component.identity, kind: component.kind, text: "", children: children))
                } else {
                    blocks.append(Block(id: component.identity, kind: component.kind, text: leaf.text))
                    index += 1
                }
            }
            return blocks
        }
        blocks = collect(depth: 0, parent: nil)
    }
}

struct MarkdownPreviewView: View {
    let model: DiffViewModel

    var body: some View {
        Group {
            switch model.markdownPreview {
            case nil:
                Color.clear
            case .loading:
                ProgressView().controlSize(.small).accessibilityLabel("Loading Markdown preview")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(Space.s5)
            case .ready(let document):
                if document.blocks.isEmpty {
                    Text("No Markdown content").typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.s4) {
                            ForEach(document.blocks) { MarkdownBlockView(block: $0) }
                        }
                        .frame(maxWidth: PanelMetrics.contentColumnMax, alignment: .leading)
                        .padding(Space.s6)
                        .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.token(.textPrimary))
                    .textSelection(.enabled)
                    .accessibilityLabel("Markdown preview")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfaceCanvas.color)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownPreviewDocument.Block
    var orderedList = false

    var body: some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .typeStyle(level == 1 ? .display : level == 2 ? .title : .headline)
                .accessibilityAddTraits(.isHeader)
        case .codeBlock:
            Text(block.text)
                .typeStyle(.monoBody)
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorToken.surfaceRaised.color, in: RoundedRectangle(cornerRadius: Radius.sm))
        case .thematicBreak:
            Divider()
        case .blockQuote:
            children(spacing: Space.s3)
                .padding(.leading, Space.s4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(ColorToken.borderSubtle.color).frame(width: Space.s1)
                }
        case .orderedList, .unorderedList:
            children(spacing: Space.s2, ordered: block.kind == .orderedList)
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(orderedList ? "\(ordinal)." : "•").typeStyle(.body)
                children(spacing: Space.s2)
            }
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(row.children) { cell in
                                Text(cell.text)
                                    .typeStyle(row.kind == .tableHeaderRow ? .headline : .body)
                                    .gridColumnAlignment(alignment(for: cell.kind, columns: columns))
                            }
                        }
                    }
                }
                .padding(Space.s4)
                .background(ColorToken.surfaceRaised.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table, \(columns.count) columns")
        default:
            Text(block.text).typeStyle(.body)
        }
    }

    private func children(spacing: CGFloat, ordered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(block.children) { MarkdownBlockView(block: $0, orderedList: ordered) }
        }
    }

    private func alignment(
        for kind: PresentationIntent.Kind, columns: [PresentationIntent.TableColumn]
    ) -> HorizontalAlignment {
        guard case .tableCell(let column) = kind, columns.indices.contains(column) else { return .leading }
        switch columns[column].alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        @unknown default: return .leading
        }
    }
}

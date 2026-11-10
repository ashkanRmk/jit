import Foundation
import Testing

@testable import Features

/// 0.0.3: the inspector's folder tree, the composer's message checks, the panel's section order.
@Suite struct FileTreeTests {
    private let paths = [
        "README.md", "src/app/views/List.swift", "src/app/views/Row.swift", "src/core/Model.swift",
        "docs/adr/0001.md",
    ]

    @Test func foldersAreClosedAtFirstAndComeBeforeFiles() {
        let rows = FileTree.rows(paths: paths, expanded: [])
        #expect(rows.map(\.name) == ["docs/adr", "src", "README.md"])
        #expect(rows.map(\.depth) == [0, 0, 0])
        #expect(rows[0].folderPath == "docs/adr")
        #expect(rows[0].fileCount == 1)
        #expect(rows[1].fileCount == 3)
        #expect(rows[1].isExpanded == false)
        #expect(rows[2].fileIndex == 0)
    }

    @Test func openingAFolderShowsItsChildrenIndented() {
        let rows = FileTree.rows(paths: paths, expanded: ["src"])
        #expect(rows.map(\.name) == ["docs/adr", "src", "app/views", "core", "README.md"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0])
        #expect(rows[1].isExpanded)
        // A chain of folders with nothing but one folder inside is one row, keyed by its full path.
        #expect(rows[2].folderPath == "src/app/views")
    }

    @Test func nestedFoldersOpenOneByOne() {
        let rows = FileTree.rows(paths: paths, expanded: ["src", "src/app/views"])
        #expect(rows.map(\.name) == ["docs/adr", "src", "app/views", "List.swift", "Row.swift", "core", "README.md"])
        #expect(rows[3].depth == 2)
        #expect(rows[3].fileIndex == 1)
        #expect(rows[4].fileIndex == 2)
    }

    @Test func aFolderWithFilesAndOneFolderIsNotMerged() {
        let rows = FileTree.rows(paths: ["a/x.txt", "a/b/y.txt"], expanded: ["a"])
        #expect(rows.map(\.name) == ["a", "b", "x.txt"])
        #expect(rows[0].fileCount == 2)
    }

    @Test func rowIdentifiersAreUnique() {
        let rows = FileTree.rows(paths: paths, expanded: ["src", "src/app/views", "src/core", "docs/adr"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.filter { $0.fileIndex != nil }.count == paths.count)
    }

    @Test func noPathsGiveNoRows() {
        #expect(FileTree.rows(paths: [], expanded: []).isEmpty)
    }
}

@Suite struct CommitMessageCheckTests {
    @Test func countsOnlyLinesOverTheLimit() {
        let short = String(repeating: "a", count: 72)
        let long = String(repeating: "b", count: 73)
        #expect(CommitMessageCheck.longLines(in: "") == 0)
        #expect(CommitMessageCheck.longLines(in: short) == 0)
        #expect(CommitMessageCheck.longLines(in: [short, "", long, long].joined(separator: "\n")) == 2)
    }
}

@Suite struct WorkingDirectorySectionOrderTests {
    @Test func unstagedComesBeforeStaged() {
        #expect(WDSection.displayOrder == [.conflicts, .unstaged, .staged])
        #expect(Set(WDSection.displayOrder) == Set(WDSection.allCases))
    }
}

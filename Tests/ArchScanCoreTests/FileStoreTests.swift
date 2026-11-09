import ArchScanCore
import Foundation
import Testing

final class FileStoreTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL {
        directory.appendingPathComponent("db/library.sqlite")
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func storesEachSupportedKindWithItsBytes() async throws {
        let store = try FileStore(databaseURL: databaseURL)
        let urls = [
            try makeFile("plan.pdf", contents: "pdf bytes"),
            try makeFile("photo.png", contents: "png bytes"),
            try makeFile("scan.jpg", contents: "jpg bytes"),
            try makeFile("scan two.JPEG", contents: "jpeg bytes"),
            try makeFile("sketch.webp", contents: "webp bytes"),
        ]

        let summary = await store.importFiles(at: urls)
        #expect(
            summary.added == ["plan.pdf", "photo.png", "scan.jpg", "scan two.JPEG", "sketch.webp"])
        #expect(summary.duplicates.isEmpty && summary.unsupported.isEmpty && summary.failed.isEmpty)

        let files = try await store.allFiles()
        let kinds = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.kind) })
        #expect(
            kinds == [
                "plan.pdf": .pdf, "photo.png": .png, "scan.jpg": .jpeg, "scan two.JPEG": .jpeg,
                "sketch.webp": .webp,
            ])

        let pdf = try #require(files.first { $0.name == "plan.pdf" })
        #expect(pdf.byteSize == 9)
        #expect(try await store.data(forFileID: pdf.id) == Data("pdf bytes".utf8))
    }

    @Test func reportsUnsupportedFoldersEmptyAndMissingFiles() async throws {
        let store = try FileStore(databaseURL: databaseURL)
        let folder = directory.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let summary = await store.importFiles(at: [
            try makeFile("notes.txt", contents: "text"),
            folder,
            try makeFile("empty.png", contents: ""),
            directory.appendingPathComponent("missing.pdf"),
        ])

        #expect(summary.added.isEmpty)
        #expect(summary.unsupported == ["notes.txt", "folder.pdf"])
        #expect(summary.failed.count == 2)
        #expect(summary.failed.first?.hasPrefix("empty.png: ") == true)
        #expect(summary.failed.last?.hasPrefix("missing.pdf: ") == true)
        #expect(try await store.allFiles().isEmpty)
    }

    @Test func skipsFilesWithIdenticalContents() async throws {
        let store = try FileStore(databaseURL: databaseURL)
        let original = try makeFile("a.png", contents: "same bytes")
        let copy = try makeFile("b.png", contents: "same bytes")

        #expect(await store.importFiles(at: [original]).added == ["a.png"])
        let second = await store.importFiles(at: [original, copy])
        #expect(second.added.isEmpty)
        #expect(second.duplicates == ["a.png", "b.png"])
        #expect(try await store.allFiles().count == 1)
    }

    @Test func deleteRemovesOnlyTheGivenFiles() async throws {
        let store = try FileStore(databaseURL: databaseURL)
        _ = await store.importFiles(at: [
            try makeFile("keep.pdf", contents: "keep"),
            try makeFile("drop.pdf", contents: "drop"),
        ])
        let doomed = try #require(try await store.allFiles().first { $0.name == "drop.pdf" })

        try await store.delete(ids: [doomed.id])

        #expect(try await store.allFiles().map(\.name) == ["keep.pdf"])
        #expect(try await store.data(forFileID: doomed.id) == nil)
    }

    @Test func filesSurviveReopeningTheDatabase() async throws {
        do {
            let store = try FileStore(databaseURL: databaseURL)
            _ = await store.importFiles(at: [try makeFile("plan.pdf", contents: "persist me")])
        }

        let reopened = try FileStore(databaseURL: databaseURL)
        let files = try await reopened.allFiles()
        #expect(files.map(\.name) == ["plan.pdf"])
        let id = try #require(files.first?.id)
        #expect(try await reopened.data(forFileID: id) == Data("persist me".utf8))
    }
}

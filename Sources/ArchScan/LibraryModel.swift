import ArchScanCore
import Foundation
import Observation

/// UI-facing state for the library: imported files and the texts extracted
/// from them. All database work happens on the `FileStore` actor; this just
/// mirrors the results on the main actor.
@MainActor
@Observable
final class LibraryModel {
    private(set) var files: [StoredFile] = []
    private(set) var texts: [StoredText] = []
    /// Result of the most recent import or removal.
    private(set) var status: String?
    /// Set when the database couldn't be opened at all.
    private(set) var storeError: String?

    private let store: FileStore?

    init() {
        do {
            store = try FileStore(databaseURL: FileStore.defaultDatabaseURL())
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
    }

    // MARK: - Files

    func reloadFiles() async {
        guard let store else { return }
        do {
            files = try await store.allFiles()
        } catch {
            status = "Couldn't read the library: \(error.localizedDescription)"
        }
    }

    func importFiles(at urls: [URL]) {
        guard let store, !urls.isEmpty else { return }
        Task {
            let summary = await store.importFiles(at: urls)
            await reloadFiles()
            status = summary.message
        }
    }

    /// The stored bytes of a file, read straight from the database for display.
    func data(for file: StoredFile) async throws -> Data {
        guard let store, let data = try await store.data(forFileID: file.id) else {
            throw StoreError.missingFile
        }
        return data
    }

    /// Removes files from the library, along with any text extracted from them.
    func delete(_ ids: Set<StoredFile.ID>) {
        guard let store, !ids.isEmpty else { return }
        Task {
            do {
                try await store.delete(ids: ids)
                status = "Removed \(ids.count) \(ids.count == 1 ? "file" : "files")"
            } catch {
                status = "Couldn't remove: \(error.localizedDescription)"
            }
            await reloadFiles()
            await reloadTexts()
        }
    }

    // MARK: - Texts

    func reloadTexts() async {
        guard let store else { return }
        // On failure the list keeps what it had; the texts are still in SQLite.
        if let loaded = try? await store.allTexts() {
            texts = loaded
        }
    }

    /// Extracts a file's text into the Texts section, replacing an earlier
    /// extraction. `progress` is called from a background thread.
    @discardableResult
    func extractText(
        from file: StoredFile,
        progress: TextExtractor.ProgressHandler? = nil
    ) async throws -> StoredText {
        guard let store else { throw StoreError.missingFile }
        let text = try await store.extractText(fromFileID: file.id, progress: progress)
        await reloadTexts()
        return text
    }

    func content(of text: StoredText) async throws -> String {
        guard let store, let content = try await store.textContent(id: text.id) else {
            throw StoreError.missingFile
        }
        return content
    }
}

import Foundation
import SQLite3

/// Metadata for one extracted text. The content itself is fetched separately
/// with `FileStore.textContent(id:)`.
public struct StoredText: Identifiable, Sendable, Hashable {
    public let id: Int64
    /// The file this text was extracted from.
    public let fileID: Int64
    /// Same name as the source file.
    public let name: String
    public let characterCount: Int
    public let method: ExtractionMethod
    public let extractedAt: Date
}

extension FileStore {
    private static let textColumns = "id, file_id, name, length(content), method, extracted_at"

    /// Extracts the text of a stored file and saves it under the file's name,
    /// replacing any text extracted from the same file earlier. PDFs are read
    /// from their embedded text where it is sound; images, and PDFs without
    /// usable text, are read by OCR. The work runs outside the actor so a
    /// large document doesn't hold up other database work.
    @concurrent
    public nonisolated func extractText(
        fromFileID id: Int64,
        progress: TextExtractor.ProgressHandler? = nil
    ) async throws -> StoredText {
        guard let source = try await textSource(forFileID: id) else {
            throw StoreError.missingFile
        }
        let extracted =
            switch source.kind {
            case .pdf:
                try TextExtractor.extract(fromPDF: source.data, progress: progress)
            case .png, .jpeg, .webp:
                try TextExtractor.extract(fromImage: source.data, progress: progress)
            }
        return try await saveText(extracted, name: source.name, fileID: id)
    }

    /// Metadata for every extracted text, newest first.
    public func allTexts() throws -> [StoredText] {
        let sql = "SELECT \(Self.textColumns) FROM texts ORDER BY extracted_at DESC, id DESC"
        return try withStatement(sql) { statement in
            try readTexts(statement)
        }
    }

    /// The full content of one text, or nil if the id doesn't exist.
    public func textContent(id: Int64) throws -> String? {
        try withStatement("SELECT content FROM texts WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, id)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            guard let bytes = sqlite3_column_text(statement, 0) else { return "" }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }

    private func textSource(forFileID id: Int64) throws -> (name: String, kind: FileKind, data: Data)? {
        try withStatement("SELECT name, kind, data FROM files WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, id)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            guard
                let name = sqlite3_column_text(statement, 0),
                let rawKind = sqlite3_column_text(statement, 1),
                let kind = FileKind(rawValue: String(cString: rawKind))
            else { return nil }
            let bytes = sqlite3_column_blob(statement, 2)
            let count = Int(sqlite3_column_bytes(statement, 2))
            return (String(cString: name), kind, bytes.map { Data(bytes: $0, count: count) } ?? Data())
        }
    }

    private func saveText(_ text: ExtractedText, name: String, fileID: Int64) throws -> StoredText {
        let upsert = """
            INSERT INTO texts (file_id, name, content, method, extracted_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(file_id) DO UPDATE SET
                name = excluded.name,
                content = excluded.content,
                method = excluded.method,
                extracted_at = excluded.extracted_at
            """
        try withStatement(upsert) { statement in
            sqlite3_bind_int64(statement, 1, fileID)
            sqlite3_bind_text(statement, 2, name, -1, sqliteTransient)
            // Explicit byte length, so the text isn't cut at an embedded NUL.
            sqlite3_bind_text(
                statement, 3, text.content, Int32(text.content.utf8.count), sqliteTransient)
            sqlite3_bind_text(statement, 4, text.method.rawValue, -1, sqliteTransient)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }

        let saved = try withStatement("SELECT \(Self.textColumns) FROM texts WHERE file_id = ?") {
            statement in
            sqlite3_bind_int64(statement, 1, fileID)
            return try readTexts(statement)
        }
        guard let stored = saved.first else { throw StoreError.missingFile }
        return stored
    }

    private func readTexts(_ statement: OpaquePointer) throws -> [StoredText] {
        var texts: [StoredText] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw lastError() }
            guard let name = sqlite3_column_text(statement, 2) else { continue }
            let method = sqlite3_column_text(statement, 4)
                .flatMap { ExtractionMethod(rawValue: String(cString: $0)) }
            texts.append(
                StoredText(
                    id: sqlite3_column_int64(statement, 0),
                    fileID: sqlite3_column_int64(statement, 1),
                    name: String(cString: name),
                    characterCount: Int(sqlite3_column_int64(statement, 3)),
                    method: method ?? .textLayer,
                    extractedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
        }
        return texts
    }
}

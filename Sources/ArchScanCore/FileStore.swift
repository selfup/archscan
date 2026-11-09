import CryptoKit
import Foundation
import SQLite3

public enum StoreError: Error, LocalizedError {
    case sqlite(String)
    case emptyFile
    case missingFile

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "SQLite error: \(message)"
        case .emptyFile: "the file is empty"
        case .missingFile: "the file is no longer in the library"
        }
    }
}

/// SQLite-backed library of imported files and the texts extracted from them
/// (see Texts.swift). File contents are stored as BLOBs, deduplicated by
/// SHA-256. The actor serializes all database access and keeps it off the
/// main thread.
public actor FileStore {
    private let connection: Connection
    var db: OpaquePointer { connection.handle }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS files (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            name      TEXT    NOT NULL,
            kind      TEXT    NOT NULL,
            byte_size INTEGER NOT NULL,
            sha256    TEXT    NOT NULL UNIQUE,
            added_at  REAL    NOT NULL,
            data      BLOB    NOT NULL
        );
        -- One text per file, named after it, and removed along with it.
        CREATE TABLE IF NOT EXISTS texts (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id      INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE,
            name         TEXT    NOT NULL,
            content      TEXT    NOT NULL,
            method       TEXT    NOT NULL DEFAULT 'text-layer',
            extracted_at REAL    NOT NULL
        );
        """

    /// Columns added after a table first shipped. `CREATE TABLE IF NOT EXISTS`
    /// leaves an existing table alone, so older databases get these added.
    private static let addedColumns = [
        (table: "texts", column: "method", definition: "TEXT NOT NULL DEFAULT 'text-layer'")
    ]

    /// `~/Library/Application Support/ArchScan/library.sqlite`
    public static func defaultDatabaseURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ArchScan", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        // SQLite only enforces foreign keys (the texts -> files cascade) when
        // asked to, once per connection.
        var setup = "PRAGMA foreign_keys = ON;" + Self.schema
        guard sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        setup = Self.addedColumns
            .filter { !Self.hasColumn($0.column, in: $0.table, handle) }
            .map { "ALTER TABLE \($0.table) ADD COLUMN \($0.column) \($0.definition);" }
            .joined()
        guard sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        connection = Connection(handle: handle)
    }

    private static func hasColumn(_ column: String, in table: String, _ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM pragma_table_info(?) WHERE name = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, column, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Importing

    /// Copies each supported file into the database. Never throws: per-file
    /// problems are reported in the summary so one bad file doesn't sink a batch.
    public func importFiles(at urls: [URL]) -> ImportSummary {
        var summary = ImportSummary()
        for url in urls {
            let name = url.lastPathComponent
            do {
                let source = url.resolvingSymlinksInPath()
                guard let kind = try Self.kind(of: source) else {
                    summary.unsupported.append(name)
                    continue
                }
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                guard !data.isEmpty else { throw StoreError.emptyFile }
                if try insert(name: name, kind: kind, data: data) {
                    summary.added.append(name)
                } else {
                    summary.duplicates.append(name)
                }
            } catch {
                summary.failed.append("\(name): \(error.localizedDescription)")
            }
        }
        return summary
    }

    /// Returns nil for folders and for anything that isn't a supported `FileKind`.
    private static func kind(of url: URL) throws -> FileKind? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, let type = values.contentType else { return nil }
        return FileKind(contentType: type)
    }

    /// Returns false when a file with identical contents is already stored.
    private func insert(name: String, kind: FileKind, data: Data) throws -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sql = """
            INSERT INTO files (name, kind, byte_size, sha256, added_at, data)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(sha256) DO NOTHING
            """
        return try withStatement(sql) { statement in
            sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, kind.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 3, Int64(data.count))
            sqlite3_bind_text(statement, 4, digest, -1, sqliteTransient)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)

            // Bind the blob without copying; it only has to outlive the step.
            let result = data.withUnsafeBytes { buffer -> Int32 in
                let bound = sqlite3_bind_blob64(
                    statement, 6, buffer.baseAddress, sqlite3_uint64(buffer.count), nil)
                return bound == SQLITE_OK ? sqlite3_step(statement) : bound
            }
            guard result == SQLITE_DONE else { throw lastError() }
            return sqlite3_changes(db) > 0
        }
    }

    // MARK: - Reading

    /// Metadata for every stored file, newest first.
    public func allFiles() throws -> [StoredFile] {
        let sql = "SELECT id, name, kind, byte_size, added_at FROM files ORDER BY added_at DESC, id DESC"
        return try withStatement(sql) { statement in
            var files: [StoredFile] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw lastError() }
                guard
                    let name = sqlite3_column_text(statement, 1),
                    let rawKind = sqlite3_column_text(statement, 2),
                    let kind = FileKind(rawValue: String(cString: rawKind))
                else { continue }
                files.append(
                    StoredFile(
                        id: sqlite3_column_int64(statement, 0),
                        name: String(cString: name),
                        kind: kind,
                        byteSize: sqlite3_column_int64(statement, 3),
                        addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                    ))
            }
            return files
        }
    }

    /// The stored bytes of one file, or nil if the id doesn't exist.
    public func data(forFileID id: Int64) throws -> Data? {
        try withStatement("SELECT data FROM files WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, id)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    // MARK: - Deleting

    /// Removes files, and with them any text extracted from them.
    public func delete(ids: Set<Int64>) throws {
        try withStatement("DELETE FROM files WHERE id = ?") { statement in
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, id)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
        }
    }

    // MARK: - Helpers

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func lastError() -> StoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

/// Owns the sqlite3 handle and closes it when the store is released.
/// Unchecked Sendable is sound because only `FileStore` touches the handle,
/// and it does so from inside its actor isolation.
private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

/// SQLITE_TRANSIENT (tells SQLite to copy the bound value); the C macro isn't imported into Swift.
var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

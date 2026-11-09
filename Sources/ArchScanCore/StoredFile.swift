import Foundation
import UniformTypeIdentifiers

/// The file formats the library accepts.
public enum FileKind: String, Sendable, CaseIterable {
    case pdf, png, jpeg, webp

    public init?(contentType: UTType) {
        if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .png) {
            self = .png
        } else if contentType.conforms(to: .jpeg) {
            self = .jpeg
        } else if contentType.conforms(to: .webP) {
            self = .webp
        } else {
            return nil
        }
    }

    public var label: String {
        switch self {
        case .pdf: "PDF"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }
}

/// Metadata for a file held in the library. The bytes stay in SQLite and are
/// fetched separately with `FileStore.data(forFileID:)`.
public struct StoredFile: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let name: String
    public let kind: FileKind
    public let byteSize: Int64
    public let addedAt: Date
}

/// What happened to each file in one import, by file name.
public struct ImportSummary: Sendable, Equatable {
    public var added: [String] = []
    public var duplicates: [String] = []
    public var unsupported: [String] = []
    /// Entries are "name: reason".
    public var failed: [String] = []

    public var message: String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append("Added \(added.count) \(added.count == 1 ? "file" : "files")")
        }
        if !duplicates.isEmpty {
            parts.append("\(duplicates.count) already in the library")
        }
        if !unsupported.isEmpty {
            parts.append("\(unsupported.count) unsupported (\(unsupported.joined(separator: ", ")))")
        }
        if !failed.isEmpty {
            parts.append("\(failed.count) failed (\(failed.joined(separator: "; ")))")
        }
        return parts.joined(separator: " · ")
    }
}

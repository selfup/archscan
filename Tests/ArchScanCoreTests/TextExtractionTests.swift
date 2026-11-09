import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing

@testable import ArchScanCore

final class TextExtractionTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private enum Page {
        /// Ordinary text: visible, and present in the text layer.
        case text(String)
        /// Looks like text but has no text layer, like a scanned page.
        case outlines(String)
        /// Looks like `shown`, while the text layer says `layer`. This is the
        /// shape of a PDF whose fonts lost their Unicode mapping.
        case mislabeled(shown: String, layer: String)
        case blank
    }

    private let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)

    private func line(_ text: String) -> CTLine {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Fills the glyph shapes of `text` as plain vector paths.
    private func drawOutlines(_ text: String, at origin: CGPoint, in context: CGContext) {
        for run in CTLineGetGlyphRuns(line(text)) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CGAffineTransform(
                    translationX: origin.x + position.x, y: origin.y + position.y)
                if let path = CTFontCreatePathForGlyph(font, glyph, &transform) {
                    context.addPath(path)
                }
            }
        }
        context.fillPath()
    }

    private func makePDF(pages: [Page]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        let origin = CGPoint(x: 40, y: 90)
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                context.textPosition = origin
                CTLineDraw(line(text), context)
            case .outlines(let text):
                drawOutlines(text, at: origin, in: context)
            case .mislabeled(let shown, let layer):
                drawOutlines(shown, at: origin, in: context)
                context.setTextDrawingMode(.invisible)
                context.textPosition = origin
                CTLineDraw(line(layer), context)
                context.setTextDrawingMode(.fill)
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PNG showing one line of black text (or nothing), on white or on a
    /// transparent background.
    private func makePNG(text: String?, transparent: Bool = false, width: Int = 1300) -> Data {
        let context = CGContext(
            data: nil, width: width, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 160))
        }
        if let text {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.textPosition = CGPoint(x: 30, y: 65)
            CTLineDraw(line(text), context)
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func makeStore() throws -> FileStore {
        try FileStore(databaseURL: directory.appendingPathComponent("db/library.sqlite"))
    }

    /// Writes `data` into the temp directory and imports it, returning the stored file.
    private func importFile(_ name: String, _ data: Data, into store: FileStore) async throws -> StoredFile {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        #expect(await store.importFiles(at: [url]).added == [name])
        return try #require(try await store.allFiles().first { $0.name == name })
    }

    /// Collects progress events from the extractor's background callback.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ExtractionProgress] = []

        func record(_ event: ExtractionProgress) {
            lock.withLock { events.append(event) }
        }

        var all: [ExtractionProgress] {
            lock.withLock { events }
        }
    }

    // MARK: - Reading the text layer

    @Test func soundTextLayerIsUsedAsIs() throws {
        let log = ProgressLog()
        let pdf = makePDF(pages: [.text("First page"), .blank, .text("Third page")])

        let result = try TextExtractor.extract(fromPDF: pdf, progress: log.record)

        #expect(result == ExtractedText(content: "First page\n\nThird page", method: .textLayer))
        // The blank page has no text layer, so it alone is offered to OCR.
        #expect(log.all == [.readingTextLayer, .recognizing(page: 2, of: 3)])
    }

    @Test func rejectsPDFsWithNoTextAnywhereAndNonPDFData() {
        #expect(throws: TextExtractionError.noText) {
            try TextExtractor.extract(fromPDF: self.makePDF(pages: [.blank, .blank]))
        }
        #expect(throws: TextExtractionError.unreadablePDF) {
            try TextExtractor.extract(fromPDF: Data("not a pdf".utf8))
        }
    }

    // MARK: - Images

    @Test func imageTextIsReadByOCR() throws {
        let log = ProgressLog()

        let result = try TextExtractor.extract(
            fromImage: makePNG(text: "Billing service"), progress: log.record)

        #expect(result == ExtractedText(content: "Billing service", method: .ocr))
        #expect(log.all == [.recognizingImage])
    }

    @Test func smallAndTransparentImagesAreStillRead() throws {
        // Narrower than the size OCR is given, so this one is enlarged first.
        let small = makePNG(text: "Order queue", width: 420)
        #expect(try TextExtractor.extract(fromImage: small).content == "Order queue")

        let transparent = makePNG(text: "Payment gateway", transparent: true)
        #expect(try TextExtractor.extract(fromImage: transparent).content == "Payment gateway")
    }

    @Test func rejectsImagesWithNoTextAndNonImageData() {
        #expect(throws: TextExtractionError.noText) {
            try TextExtractor.extract(fromImage: self.makePNG(text: nil))
        }
        #expect(throws: TextExtractionError.unreadableImage) {
            try TextExtractor.extract(fromImage: Data("not an image".utf8))
        }
    }

    // MARK: - Falling back to OCR

    @Test func pageWithoutATextLayerIsReadByOCR() throws {
        let pdf = makePDF(pages: [.outlines("Scanned quarterly report")])

        let result = try TextExtractor.extract(fromPDF: pdf)

        #expect(result.method == .ocr)
        #expect(result.content == "Scanned quarterly report")
    }

    @Test func damagedTextLayerIsReplacedByOCRForTheWholeDocument() throws {
        let log = ProgressLog()
        let pdf = makePDF(pages: [
            .mislabeled(shown: "Thank you for reading", layer: "Th\u{E061}nk you for r\u{E065}\u{E061}ding"),
            // Sound on its own, but not trusted once the document shows damage.
            .text("Second page here"),
        ])

        let result = try TextExtractor.extract(fromPDF: pdf, progress: log.record)

        #expect(result.method == .ocr)
        #expect(result.content == "Thank you for reading\n\nSecond page here")
        #expect(
            log.all == [.readingTextLayer, .recognizing(page: 1, of: 2), .recognizing(page: 2, of: 2)])
    }

    @Test func scannedPagesAreAddedToASoundTextLayer() throws {
        let pdf = makePDF(pages: [.text("Typed cover page"), .outlines("Scanned appendix")])

        let result = try TextExtractor.extract(fromPDF: pdf)

        #expect(result == ExtractedText(content: "Typed cover page\n\nScanned appendix", method: .mixed))
    }

    // MARK: - Judging the text layer

    @Test func damageCountsUnmappedCharactersThatFollowLettersInAWord() {
        #expect(TextExtractor.damagedShare(of: "Thank you for purchasing") == 0)
        #expect(TextExtractor.damagedShare(of: "") == 0)
        // One lost letter among five word characters.
        #expect(TextExtractor.damagedShare(of: "Th\u{E061}nk") == 0.2)
        #expect(TextExtractor.damagedShare(of: "caf\u{FFFD}") == 0.25)
        // Symbol-font bullets and icons stand alone or lead a word: not damage.
        #expect(TextExtractor.damagedShare(of: "\u{F0B7} First item\n\u{F0B7}Second item \u{E800}") == 0)
        #expect(TextExtractor.damagedShare(of: "Th\u{E061}nk") >= TextExtractor.damageThreshold)
    }

    @Test func intactWordsSkipDamagedAndVeryShortTokens() {
        let words = TextExtractor.intactWords(in: "Oct\u{E061}tr\u{E061}ck MKII is on, th\u{E065} 2nd MKII")
        #expect(words == ["2nd", "MKII"])
    }

    // MARK: - Storing

    @Test func extractedTextIsStoredUnderThePDFsName() async throws {
        let store = try makeStore()
        let file = try await importFile("guide.pdf", makePDF(pages: [.text("Hello"), .text("World")]), into: store)

        let text = try await store.extractText(fromFileID: file.id)

        #expect(text.name == "guide.pdf")
        #expect(text.fileID == file.id)
        #expect(text.method == .textLayer)
        #expect(text.characterCount == "Hello\n\nWorld".count)
        #expect(try await store.textContent(id: text.id) == "Hello\n\nWorld")
        #expect(try await store.allTexts() == [text])
    }

    @Test func extractingAgainReplacesTheEarlierText() async throws {
        let store = try makeStore()
        let file = try await importFile("guide.pdf", makePDF(pages: [.text("Hello")]), into: store)

        let first = try await store.extractText(fromFileID: file.id)
        let second = try await store.extractText(fromFileID: file.id)

        #expect(second.id == first.id)
        #expect(try await store.allTexts().count == 1)
    }

    @Test func theMethodIsStoredWithTheText() async throws {
        let store = try makeStore()
        let file = try await importFile("scan.pdf", makePDF(pages: [.outlines("Scanned memo")]), into: store)

        let text = try await store.extractText(fromFileID: file.id)

        #expect(text.method == .ocr)
        #expect(try await store.allTexts().map(\.method) == [.ocr])
        #expect(try await store.textContent(id: text.id) == "Scanned memo")
    }

    @Test func imageTextIsStoredUnderTheImagesName() async throws {
        let store = try makeStore()
        let file = try await importFile("diagram.png", makePNG(text: "Auth service"), into: store)

        let text = try await store.extractText(fromFileID: file.id)

        #expect(text.name == "diagram.png")
        #expect(text.method == .ocr)
        #expect(try await store.textContent(id: text.id) == "Auth service")
    }

    @Test func nothingIsStoredWhenExtractionFails() async throws {
        let store = try makeStore()
        let image = try await importFile("photo.png", Data("png bytes".utf8), into: store)
        let empty = try await importFile("empty.pdf", makePDF(pages: [.blank]), into: store)

        await #expect(throws: TextExtractionError.unreadableImage) {
            _ = try await store.extractText(fromFileID: image.id)
        }
        await #expect(throws: TextExtractionError.noText) {
            _ = try await store.extractText(fromFileID: empty.id)
        }
        await #expect(throws: StoreError.self) {
            _ = try await store.extractText(fromFileID: 9_999)
        }
        #expect(try await store.allTexts().isEmpty)
    }

    @Test func removingAFileRemovesItsText() async throws {
        let store = try makeStore()
        let kept = try await importFile("kept.pdf", makePDF(pages: [.text("Keep")]), into: store)
        let removed = try await importFile("removed.pdf", makePDF(pages: [.text("Remove")]), into: store)
        _ = try await store.extractText(fromFileID: kept.id)
        let doomed = try await store.extractText(fromFileID: removed.id)

        try await store.delete(ids: [removed.id])

        #expect(try await store.allTexts().map(\.name) == ["kept.pdf"])
        #expect(try await store.textContent(id: doomed.id) == nil)
    }

    @Test func databaseFromBeforeTheMethodColumnIsUpgradedInPlace() async throws {
        // The texts table as it first shipped, holding one text.
        let url = directory.appendingPathComponent("old/library.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let oldSchema = """
            CREATE TABLE files (
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
                byte_size INTEGER NOT NULL, sha256 TEXT NOT NULL UNIQUE, added_at REAL NOT NULL,
                data BLOB NOT NULL);
            CREATE TABLE texts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE,
                name TEXT NOT NULL, content TEXT NOT NULL, extracted_at REAL NOT NULL);
            INSERT INTO files (name, kind, byte_size, sha256, added_at, data)
                VALUES ('old.pdf', 'pdf', 1, 'abc', 1, x'00');
            INSERT INTO texts (file_id, name, content, extracted_at) VALUES (1, 'old.pdf', 'Old text', 1);
            """
        #expect(sqlite3_exec(handle, oldSchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let store = try FileStore(databaseURL: url)
        let texts = try await store.allTexts()

        #expect(texts.map(\.name) == ["old.pdf"])
        #expect(texts.map(\.method) == [.textLayer])
        #expect(try await store.textContent(id: try #require(texts.first).id) == "Old text")
        // Opening it a second time must not try to add the column again.
        _ = try FileStore(databaseURL: url)
    }
}

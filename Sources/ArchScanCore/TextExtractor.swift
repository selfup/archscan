import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// How an extracted text was obtained.
public enum ExtractionMethod: String, Sendable {
    /// Read from the PDF's embedded text.
    case textLayer = "text-layer"
    /// Recognized from the rendered pages, because the embedded text was
    /// missing or damaged. May contain recognition mistakes.
    case ocr
    /// Embedded text where pages had it, OCR for the pages that had none.
    case mixed
}

public struct ExtractedText: Sendable, Equatable {
    public let content: String
    public let method: ExtractionMethod
}

public enum ExtractionProgress: Sendable, Equatable {
    case readingTextLayer
    /// OCR of one PDF page. `page` counts from 1.
    case recognizing(page: Int, of: Int)
    /// OCR of an image file.
    case recognizingImage
}

public enum TextExtractionError: Error, LocalizedError {
    case unreadablePDF
    case unreadableImage
    case lockedPDF
    case noText

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF: "This PDF couldn't be read."
        case .unreadableImage: "This image couldn't be read."
        case .lockedPDF: "This PDF is password-protected."
        case .noText: "No text was found."
        }
    }
}

public enum TextExtractor {
    public typealias ProgressHandler = @Sendable (ExtractionProgress) -> Void

    /// At or above this share of damaged word characters (see `damagedShare`),
    /// the embedded text is not trusted and every page is read by OCR instead.
    static let damageThreshold = 0.01

    /// Pages are rendered at 144 dpi for OCR. On the sample that prompted
    /// this, higher resolutions were slower and no more accurate.
    private static let renderScale: CGFloat = 2

    /// Images smaller than this on their long side are enlarged to it before
    /// OCR. Tuned on five small architecture diagrams: at their native 800 px
    /// some short labels ("S3", "EC2") were missed, and enlarging further
    /// than this made OCR start reading icons as text.
    private static let minimumLongSideForOCR: CGFloat = 1200

    /// The text in an image, read by OCR: one line per line of text found, in
    /// the order Vision reports them.
    public static func extract(
        fromImage data: Data,
        progress: ProgressHandler? = nil
    ) throws -> ExtractedText {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TextExtractionError.unreadableImage }

        progress?(.recognizingImage)
        // Photos are often stored sideways with a tag saying which way is up.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:))

        let text = try recognizeText(
            in: preparedForOCR(image), orientation: orientation ?? .up, vocabulary: [])
        guard !text.isEmpty else { throw TextExtractionError.noText }
        return ExtractedText(content: text, method: .ocr)
    }

    /// The text of a PDF, with a blank line between pages.
    ///
    /// The PDF's embedded text is exact when it is sound, so it is used when
    /// possible. Some PDFs embed text that cannot be read back: browser
    /// "print to PDF" output, for one, can store letters as private-use code
    /// points. When that damage is found the whole document is read by OCR,
    /// and a page with no embedded text at all (a scan) is always read by OCR.
    public static func extract(
        fromPDF data: Data,
        progress: ProgressHandler? = nil
    ) throws -> ExtractedText {
        guard let document = PDFDocument(data: data) else {
            throw TextExtractionError.unreadablePDF
        }
        guard !document.isLocked else { throw TextExtractionError.lockedPDF }

        progress?(.readingTextLayer)
        let pageCount = document.pageCount
        let layer = (0..<pageCount).map { index in
            (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isDamaged = damagedShare(of: layer.joined(separator: "\n")) >= damageThreshold

        var pages: [String] = []
        var usedLayer = false
        var usedOCR = false
        for index in 0..<pageCount {
            if !isDamaged && !layer[index].isEmpty {
                pages.append(layer[index])
                usedLayer = true
                continue
            }
            progress?(.recognizing(page: index + 1, of: pageCount))
            guard let page = document.page(at: index) else { continue }
            let recognized = try recognizeText(on: page, vocabulary: intactWords(in: layer[index]))
            if !recognized.isEmpty {
                pages.append(recognized)
                usedOCR = true
            }
        }

        guard !pages.isEmpty else { throw TextExtractionError.noText }
        let method: ExtractionMethod = usedOCR ? (usedLayer ? .mixed : .ocr) : .textLayer
        return ExtractedText(content: pages.joined(separator: "\n\n"), method: method)
    }

    // MARK: - Judging the embedded text

    /// The share of word characters that are unmapped (private-use or
    /// replacement characters) and follow a real letter in the same word, as
    /// in "Th\u{E061}nk". That pattern means letters were lost. An unmapped
    /// character standing alone or starting a word is usually an icon or a
    /// bullet from a symbol font, which is harmless, so those don't count.
    static func damagedShare(of text: String) -> Double {
        var letters = 0
        var damaged = 0
        var lettersInWord = 0
        for scalar in text.unicodeScalars {
            if isUnmapped(scalar) {
                if lettersInWord > 0 { damaged += 1 }
            } else if scalar.properties.isAlphabetic {
                letters += 1
                lettersInWord += 1
            } else {
                lettersInWord = 0
            }
        }
        let total = letters + damaged
        return total == 0 ? 0 : Double(damaged) / Double(total)
    }

    /// Words the embedded text still spells with ordinary letters and digits.
    /// Even in a damaged text layer these are exact, which makes them a good
    /// vocabulary hint for OCR: names and jargon are what it misreads most.
    static func intactWords(in text: String) -> [String] {
        // Unmapped characters stay inside their token, so a damaged word is
        // dropped whole instead of leaving its fragments behind as "words".
        let isWordCharacter = { (character: Character) in
            character.isLetter || character.isNumber
                || character.unicodeScalars.contains(where: isUnmapped)
        }
        var words = Set<String>()
        for token in text.split(whereSeparator: { !isWordCharacter($0) })
        where token.count >= 3 && !token.unicodeScalars.contains(where: isUnmapped) {
            words.insert(String(token))
        }
        return words.sorted()
    }

    private static func isUnmapped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD, 0xFFFD: true
        default: false
        }
    }

    // MARK: - OCR

    private static func recognizeText(on page: PDFPage, vocabulary: [String]) throws -> String {
        guard let image = render(page) else { return "" }
        return try recognizeText(in: image, orientation: .up, vocabulary: vocabulary)
    }

    private static func recognizeText(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        vocabulary: [String]
    ) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = vocabulary
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Enlarges a small image (see `minimumLongSideForOCR`) and puts any
    /// transparency on white, since OCR needs a background to read against.
    /// An image that needs neither is returned as is.
    private static func preparedForOCR(_ image: CGImage) -> CGImage {
        let longSide = CGFloat(max(image.width, image.height))
        let factor = max(1, minimumLongSideForOCR / longSide)
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard factor > 1 || !isOpaque else { return image }

        let width = Int((CGFloat(image.width) * factor).rounded())
        let height = Int((CGFloat(image.height) * factor).rounded())
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    /// The page as a viewer would show it, on a white background.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        // PDFKit applies the page's rotation when drawing, so a sideways page
        // needs a bitmap with the sides swapped.
        let isSideways = page.rotation % 180 != 0
        let size = isSideways ? CGSize(width: box.height, height: box.width) : box.size
        let width = Int((size.width * renderScale).rounded())
        let height = Int((size.height * renderScale).rounded())
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: renderScale, y: renderScale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

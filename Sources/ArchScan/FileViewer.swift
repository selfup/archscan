import ArchScanCore
import PDFKit
import SwiftUI

/// Shows one stored file inside the app, filling the Files pane, under a bar
/// of actions that stays put while the document scrolls.
struct FileViewer: View {
    let file: StoredFile
    let library: LibraryModel
    @ViewState private var preview = Preview.loading
    @ViewState private var extraction = Extraction.idle

    private enum Preview {
        case loading
        case image(NSImage)
        case pdf(PDFDocument)
        case failed(String)
    }

    private enum Extraction: Equatable {
        case idle
        /// Carries the progress message shown in the bar.
        case running(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            Group {
                switch preview {
                case .loading:
                    ProgressView()
                case .image(let image):
                    ImagePreview(image: image)
                case .pdf(let document):
                    PDFPreview(document: document)
                case .failed(let message):
                    ContentUnavailableView(
                        "Can't show this file",
                        systemImage: "eye.slash",
                        description: Text(message)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(file.name)
        .task(id: file.id) {
            preview = await load()
        }
        // So the bar can say whether this file's text is already in Texts.
        .task { await library.reloadTexts() }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                extractText()
            } label: {
                Label("Extract Text", systemImage: "text.viewfinder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(extraction.isRunning)

            if extraction.isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text(extractionStatus)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The text already extracted from this file, if any.
    private var savedText: StoredText? {
        library.texts.first { $0.fileID == file.id }
    }

    private var extractionStatus: String {
        switch extraction {
        case .running(let message):
            return message
        case .failed(let message):
            return message
        case .idle:
            if let savedText {
                return "Saved in Texts · \(savedText.characterCount.formatted()) characters"
                    + " · \(savedText.method.label)"
            }
            return ""
        }
    }

    private func extractText() {
        extraction = .running("Reading text…")
        Task {
            do {
                try await library.extractText(from: file) { progress in
                    // Called off the main thread. An update that lands after
                    // the extraction has finished is dropped.
                    Task { @MainActor in
                        if extraction.isRunning {
                            extraction = .running(Self.describe(progress))
                        }
                    }
                }
                extraction = .idle
            } catch {
                extraction = .failed(error.localizedDescription)
            }
        }
    }

    private static func describe(_ progress: ExtractionProgress) -> String {
        switch progress {
        case .readingTextLayer:
            "Reading text…"
        case .recognizing(let page, let total):
            "Reading page \(page) of \(total) with OCR…"
        case .recognizingImage:
            "Reading text with OCR…"
        }
    }

    // MARK: - Preview

    private func load() async -> Preview {
        do {
            let data = try await library.data(for: file)
            switch file.kind {
            case .pdf:
                guard let document = PDFDocument(data: data) else {
                    return .failed("This PDF couldn't be read.")
                }
                return .pdf(document)
            case .png, .jpeg, .webp:
                guard let image = NSImage(data: data), image.isValid,
                    image.size.width > 0, image.size.height > 0
                else {
                    return .failed("This image couldn't be decoded.")
                }
                return .image(image)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Fits the image to the pane, but never enlarges it past its natural size.
private struct ImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// PDFKit's viewer: continuous scrolling through pages, with pinch to zoom.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}

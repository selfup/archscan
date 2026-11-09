import AppKit
import ArchScanCore
import SwiftUI

/// The Texts section: every extracted text, each named after its source file.
struct TextsView: View {
    let library: LibraryModel
    @ViewState private var selection = Set<StoredText.ID>()
    /// The text open in the reader; nil shows the list.
    @ViewState private var viewedText: StoredText?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Texts")
                .navigationDestination(item: $viewedText) { text in
                    TextReader(text: text, library: library)
                }
                .task { await library.reloadTexts() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = library.storeError {
            ContentUnavailableView(
                "Couldn't open the library",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if library.texts.isEmpty {
            ContentUnavailableView(
                "No texts yet",
                systemImage: "text.alignleft",
                description: Text("Open a file in Files and choose Extract Text.")
            )
        } else {
            Table(library.texts, selection: $selection) {
                TableColumn("") { text in
                    Button("View") {
                        viewedText = text
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .width(52)
                TableColumn("Name") { text in
                    Label(text.name, systemImage: "text.alignleft")
                }
                TableColumn("Characters") { text in
                    Text(text.characterCount, format: .number)
                }
                .width(100)
                TableColumn("Source") { text in
                    Text(text.method.label)
                }
                .width(130)
                TableColumn("Extracted") { text in
                    Text(text.extractedAt, format: .dateTime.year().month().day().hour().minute())
                }
                .width(180)
            }
        }
    }
}

extension ExtractionMethod {
    /// How the text was obtained, as shown next to it. OCR is worth flagging
    /// because recognized text can contain mistakes; embedded text cannot.
    var label: String {
        switch self {
        case .textLayer: "PDF text"
        case .ocr: "OCR"
        case .mixed: "PDF text + OCR"
        }
    }
}

/// Shows one extracted text, read from the database when opened.
private struct TextReader: View {
    let text: StoredText
    let library: LibraryModel
    @ViewState private var content: Result<String, LoadFailure>?

    private struct LoadFailure: Error {
        let message: String
    }

    var body: some View {
        Group {
            switch content {
            case nil:
                ProgressView()
            case .success(let string):
                ReadOnlyTextView(text: string)
            case .failure(let failure):
                ContentUnavailableView(
                    "Can't show this text",
                    systemImage: "eye.slash",
                    description: Text(failure.message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(text.name)
        .task(id: text.id) {
            do {
                content = .success(try await library.content(of: text))
            } catch {
                content = .failure(LoadFailure(message: error.localizedDescription))
            }
        }
    }
}

/// A scrolling, selectable, non-editable text view. AppKit's text view stays
/// fast on book-length text, where a SwiftUI `Text` would not.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .systemFont(ofSize: 14)
            // Set explicitly so the text follows light and dark appearance.
            textView.textColor = .labelColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 24, height: 20)
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
            return
        }
        textView.string = text
    }
}

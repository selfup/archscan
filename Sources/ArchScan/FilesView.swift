import ArchScanCore
import SwiftUI

struct FilesView: View {
    let library: LibraryModel
    @ViewState private var selection = Set<StoredFile.ID>()
    @ViewState private var isDropTargeted = false
    /// The file open in the viewer; nil shows the list.
    @ViewState private var viewedFile: StoredFile?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                // Finder drags arrive as file URLs. The whole pane is the target,
                // so dropping on the table works the same as on the empty state.
                .dropDestination(for: URL.self) { urls, _ in
                    library.importFiles(at: urls)
                    return !urls.isEmpty
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }
                .navigationTitle("Files")
                .navigationDestination(item: $viewedFile) { file in
                    FileViewer(file: file, library: library)
                }
                .task { await library.reloadFiles() }
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
        } else if library.files.isEmpty {
            ContentUnavailableView(
                "Drop files here",
                systemImage: "square.and.arrow.down",
                description: Text("Drag PDF, PNG, JPEG, or WebP files in from Finder.")
            )
        } else {
            table
        }
    }

    private var table: some View {
        Table(library.files, selection: $selection) {
            TableColumn("") { file in
                Button("View") {
                    viewedFile = file
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(52)
            TableColumn("Name") { file in
                Label(file.name, systemImage: file.kind.symbol)
            }
            TableColumn("Kind") { file in
                Text(file.kind.label)
            }
            .width(70)
            TableColumn("Size") { file in
                Text(file.byteSize, format: .byteCount(style: .file))
            }
            .width(90)
            TableColumn("Added") { file in
                Text(file.addedAt, format: .dateTime.year().month().day().hour().minute())
            }
            .width(180)
        }
        .contextMenu(forSelectionType: StoredFile.ID.self) { ids in
            if !ids.isEmpty {
                Button("Remove from Library", role: .destructive) {
                    library.delete(ids)
                }
            }
        }
        .onDeleteCommand {
            library.delete(selection)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(library.files.count == 1 ? "1 file" : "\(library.files.count) files")
            Spacer()
            Text(library.status ?? "Drop PDF, PNG, JPEG, or WebP files to add them")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

extension FileKind {
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .png, .jpeg, .webp: "photo"
        }
    }
}

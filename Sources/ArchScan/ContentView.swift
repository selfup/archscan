import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case files, crops, texts, summaries, diagrams

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .crops: "crop"
        case .texts: "text.alignleft"
        case .summaries: "list.bullet.rectangle"
        case .diagrams: "rectangle.3.group"
        }
    }
}

struct ContentView: View {
    let library: LibraryModel
    @ViewState private var selection: SidebarSection? = .files

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            switch selection {
            case .files:
                FilesView(library: library)
            case .texts:
                TextsView(library: library)
            case let section?:
                ContentUnavailableView(
                    section.title,
                    systemImage: section.symbol,
                    description: Text("Nothing here yet.")
                )
                .navigationTitle(section.title)
            case nil:
                ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        }
    }
}

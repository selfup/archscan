import SwiftUI

@main
struct ArchScanApp: App {
    @ViewState private var library = LibraryModel()

    var body: some Scene {
        Window("ArchScan", id: "main") {
            ContentView(library: library)
                .background(FillScreenOnLaunch())
        }
    }
}

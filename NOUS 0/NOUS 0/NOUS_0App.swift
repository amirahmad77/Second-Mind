import SwiftUI
import SwiftData

@main
struct NOUS_0App: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [NoteEventRecord.self, EmbeddingRecord.self])
    }
}

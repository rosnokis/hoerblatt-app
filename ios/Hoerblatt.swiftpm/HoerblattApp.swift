import SwiftUI

// Entry point: one AppState for the whole app (Mappe, open pages, settings, speaking).

@main
struct HoerblattApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            // fixed light look: the picture-card colours sit on white cards, also on an iPad set to dark mode
            ContentView(app: app)
                .preferredColorScheme(.light)
        }
    }
}

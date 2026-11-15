import SwiftUI

// Entry point: one AppState for the whole app (Mappe, open pages, settings, speaking).

@main
struct HoerblattApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            // fixed light look: the picture-card colours sit on white cards, also on an iPad set to dark mode
            HoerblattRoot(app: app)
                .preferredColorScheme(.light)
        }
    }
}

/// The screen in the chosen typeface; built anew when the teacher chooses another one (Fonts.swift).
struct HoerblattRoot: View {
    @ObservedObject var app: AppState

    var body: some View {
        ContentView(app: app)
            .font(.hb(.body))
            .id(app.fontGeneration)
    }
}

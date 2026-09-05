import SwiftUI
import SwiftData
import HRVKit

@main
struct NocturneApp: App {

    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: StoredNight.self)
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var repository: NightRepository?

    var body: some View {
        Group {
            if let repository {
                MainTabView(repository: repository)
            } else {
                ProgressView().task { repository = NightRepository(context: context) }
            }
        }
    }
}

struct MainTabView: View {
    @Bindable var repository: NightRepository

    var body: some View {
        TabView {
            TonightView(repository: repository)
                .tabItem { Label("Tonight", systemImage: "moon.stars") }
            TrendView(repository: repository)
                .tabItem { Label("Trend", systemImage: "chart.xyaxis.line") }
            DataView(repository: repository)
                .tabItem { Label("Data", systemImage: "tray.full") }
            MethodsView()
                .tabItem { Label("Methods", systemImage: "text.book.closed") }
        }
        .task {
            await repository.requestAuthorization()
            await repository.refresh()
        }
    }
}

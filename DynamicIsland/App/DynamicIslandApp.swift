import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No WindowGroup — this app has no ordinary window. Settings{} is the
        // smallest legal Scene that satisfies App's requirement without
        // producing a visible window at launch.
        Settings {
            EmptyView()
        }
    }
}

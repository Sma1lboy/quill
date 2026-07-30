import SwiftUI

@main
struct QuillIOSApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
    }
}

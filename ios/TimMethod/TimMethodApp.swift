import SwiftUI
import TimMethodCore

@main
struct TimMethodApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Tim Method \(TimMethodCore.version)")
    }
}

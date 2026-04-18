import SwiftUI

@main
struct BlueBubbleBudsApp: App {
    var body: some Scene {
        WindowGroup("Blue Bubble Buds") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

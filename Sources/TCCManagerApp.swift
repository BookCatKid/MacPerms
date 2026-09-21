import SwiftUI

@main
struct TCCManagerApp: App {
    @StateObject private var model = TCCViewModel()

    var body: some Scene {
        WindowGroup("TCC Manager") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
        }
    }
}

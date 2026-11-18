import SwiftUI

// The neutral sample app for the README demo: one screen, no services.
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("MyApp")
                    .font(.largeTitle.bold())
                Text("Running on a light simulator")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

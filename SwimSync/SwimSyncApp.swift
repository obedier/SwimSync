import SwiftUI

@main
struct SwimSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @StateObject private var library = LibraryStore()
    @StateObject private var monitor = DeviceMonitor()
    @StateObject private var transfer = TransferEngine(hygiene: MacHygiene())

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SwimSync", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(monitor)
                .environmentObject(transfer)
                .frame(minWidth: 940, minHeight: 620)
                .background(Theme.bg)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Hand the delegate a way to reopen this scene after ⌘W.
                    AppDelegate.openMainWindow = { openWindow(id: "main") }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh Library") {
                    Task { await library.scan() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

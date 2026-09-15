import SwiftUI

@main
struct SwimSyncMobileApp: App {
    @StateObject private var drive = DriveStore()
    @StateObject private var library = MobileLibrary()
    // iOS writes through the Files provider, which handles its own metadata —
    // none of the macOS Spotlight/AppleDouble housekeeping applies here.
    @StateObject private var transfer = TransferEngine()
    @StateObject private var downloader = EpisodeDownloader()
    @StateObject private var podcasts = PodcastLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(drive)
                .environmentObject(library)
                .environmentObject(transfer)
                .environmentObject(downloader)
                .environmentObject(podcasts)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

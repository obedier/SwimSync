import SwiftUI

@main
struct SwimSyncMobileApp: App {
    @StateObject private var drive = DriveStore()
    @StateObject private var library = MobileLibrary()
    // iOS writes through the system's own FAT driver, which handles its own
    // metadata — none of the macOS Spotlight/AppleDouble housekeeping applies.
    // What iOS needs instead is to keep the phone awake for the duration.
    @StateObject private var transfer = TransferEngine(hygiene: MobileHygiene())
    @StateObject private var downloader = EpisodeDownloader()
    @StateObject private var podcasts = PodcastLibrary()
    @StateObject private var music = MusicLibrarySource()
    @StateObject private var speech = SpeechMaker()
    @StateObject private var inbox = Inbox()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(drive)
                .environmentObject(library)
                .environmentObject(transfer)
                .environmentObject(downloader)
                .environmentObject(podcasts)
                .environmentObject(music)
                .environmentObject(speech)
                .environmentObject(inbox)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // "Open in SwimSync" from the share sheet or Files lands here.
                .onOpenURL { url in inbox.receive(url, into: library) }
        }
    }
}

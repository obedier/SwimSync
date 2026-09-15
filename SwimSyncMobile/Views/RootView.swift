import SwiftUI

/// Two halves of one job: find something worth listening to, then get it onto
/// the player. They stay separate tabs because the second one is useless
/// without the drive attached, and the first one is useful anywhere.
struct RootView: View {
    @EnvironmentObject var library: MobileLibrary
    @EnvironmentObject var downloader: EpisodeDownloader
    @EnvironmentObject var podcasts: PodcastLibrary
    @EnvironmentObject var music: MusicLibrarySource
    @EnvironmentObject var inbox: Inbox
    @EnvironmentObject var videos: VideoExtractor

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.find

    enum Tab: Hashable { case find, music, transfer }

    var body: some View {
        TabView(selection: $tab) {
            DiscoverView()
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(Tab.find)

            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(Tab.music)

            TransferView()
                .tabItem { Label("Transfer", systemImage: "arrow.up.circle") }
                .tag(Tab.transfer)
                .badge(library.queue.count)
        }
        .tint(Theme.library)
        // A text file handed to the app from anywhere opens the speech sheet.
        .sheet(item: $inbox.pendingText) { document in
            SpeechView(document: document)
        }
        .alert("Something went wrong", isPresented: inboxProblem) {
            Button("OK") { inbox.problem = nil }
        } message: {
            Text(inbox.problem ?? "")
        }
        // The share extension can only leave things in the app-group inbox;
        // this is where they are picked up.
        .task { await SharedInbox.drain(into: inbox, library: library, videos: videos) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await SharedInbox.drain(into: inbox, library: library, videos: videos) }
        }
        .task {
            // A finished download is only useful if it lands in the queue, so
            // the two are joined here rather than making the user re-add the
            // file through the Files picker it just bypassed.
            // The same moment is when the show earns its place in history —
            // "downloaded before" is only true once the bytes have landed.
            downloader.onComplete = { episode, show, url in
                library.add([url])
                if let show { podcasts.recordDownload(episode, from: show) }
            }
            music.onExported = { _, url in
                library.add([url])
            }
            videos.onExtracted = { url in
                library.add([url])
            }
        }
    }

    private var inboxProblem: Binding<Bool> {
        Binding(get: { inbox.problem != nil }, set: { if !$0 { inbox.problem = nil } })
    }
}

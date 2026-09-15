import SwiftUI

/// Two halves of one job: find something worth listening to, then get it onto
/// the player. They stay separate tabs because the second one is useless
/// without the drive attached, and the first one is useful anywhere.
struct RootView: View {
    @EnvironmentObject var library: MobileLibrary
    @EnvironmentObject var downloader: EpisodeDownloader
    @EnvironmentObject var podcasts: PodcastLibrary

    @State private var tab = Tab.find

    enum Tab: Hashable { case find, transfer }

    var body: some View {
        TabView(selection: $tab) {
            DiscoverView()
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(Tab.find)

            TransferView()
                .tabItem { Label("Transfer", systemImage: "arrow.up.circle") }
                .tag(Tab.transfer)
                .badge(library.queue.count)
        }
        .tint(Theme.library)
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
        }
    }
}

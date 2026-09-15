import SwiftUI

/// Videos whose audio is being pulled out right now. Sits above the queue,
/// since that is where each one lands when it finishes.
struct ConvertingCard: View {
    @EnvironmentObject var videos: VideoExtractor

    var body: some View {
        if !videos.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Extracting audio", tint: Theme.music)
                ForEach(videos.jobs) { job in
                    HStack(spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.music)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            ProgressView(value: job.progress)
                                .tint(Theme.music)
                        }
                        Spacer(minLength: 4)
                        Button { videos.cancel(job) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textFaint.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel")
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}

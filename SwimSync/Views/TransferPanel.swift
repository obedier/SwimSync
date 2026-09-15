import SwiftUI

/// Live transfer progress. On a ~1 MB/s link a single episode can take two
/// minutes, so this shows real per-file byte progress and a measured rate
/// rather than an indeterminate spinner.
struct TransferPanel: View {
    @EnvironmentObject var transfer: TransferEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(
                    text: transfer.isRunning ? "Transferring" : "Finished",
                    tint: transfer.isRunning ? Theme.accent : Theme.ok
                )
                Spacer()
                if transfer.isRunning {
                    Text(Fmt.rate(transfer.observedRate))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }

            if transfer.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: transfer.overallProgress)
                        .tint(Theme.accent)
                    HStack {
                        Text("\(Fmt.bytes(transfer.bytesDone)) of \(Fmt.bytes(transfer.bytesTotal))")
                        Spacer()
                        Text("\(transfer.etaRemaining) left")
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                }
            }

            if let summary = transfer.finishedSummary {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Clear") { transfer.reset() }
                    .buttonStyle(PillButton(tint: Theme.textDim))
            }

            if !transfer.items.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(transfer.items.enumerated()), id: \.element.id) { _, item in
                        ItemRow(item: item)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .panel()
    }
}

private struct ItemRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(item.destinationName)
                .font(.system(size: 10.5))
                .foregroundStyle(item.state == .waiting ? Theme.textFaint : Theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)

            if case .copying = item.state {
                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else if case .failed(let why) = item.state {
                Text(why).font(.system(size: 9.5)).foregroundStyle(Theme.warn).lineLimit(1)
            } else if case .skipped(let why) = item.state {
                Text(why).font(.system(size: 9.5)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting:
            Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
        case .copying:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.ok)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.warn)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
        }
    }
}

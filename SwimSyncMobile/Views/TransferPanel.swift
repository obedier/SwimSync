import SwiftUI

struct TransferPanel: View {
    /// Asked to send one item again — after a failure, or to overwrite a copy
    /// that landed but doesn't play.
    var onResend: ((TransferItem) -> Void)?

    @EnvironmentObject var transfer: TransferEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: transfer.isRunning ? "Transferring" : "Done", tint: Theme.accent)

            if transfer.isRunning {
                progress
            }

            if let summary = transfer.finishedSummary {
                Text(summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ok)
            }

            if !transfer.items.isEmpty {
                VStack(spacing: 5) {
                    ForEach(transfer.items) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bg)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(3, geo.size.width * transfer.overallProgress))
                }
            }
            .frame(height: 7)

            HStack {
                Text("\(Fmt.bytes(transfer.bytesDone)) of \(Fmt.bytes(transfer.bytesTotal))")
                Spacer()
                if transfer.observedRate > 0 {
                    Text("\(Fmt.rate(transfer.observedRate)) · \(transfer.etaRemaining) left")
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textFaint)
        }
    }

    private func itemRow(_ item: TransferItem) -> some View {
        HStack(spacing: 9) {
            icon(for: item.state)
                .font(.system(size: 12))
                .frame(width: 14)

            Text(item.destinationName)
                .font(.system(size: 12))
                .foregroundStyle(item.state == .waiting ? Theme.textFaint : Theme.textDim)
                .lineLimit(1)

            Spacer(minLength: 4)

            trailing(item)
        }
    }

    /// Status text while running; a resend control once the run is over.
    /// "Send again" is offered on success too, because a copy can report
    /// every byte landed and still produce a track the player rejects.
    @ViewBuilder
    private func trailing(_ item: TransferItem) -> some View {
        switch item.state {
        case .copying:
            Text("\(Int(item.progress * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.accent)

        case .failed(let why):
            HStack(spacing: 8) {
                Text(why)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warn)
                    .lineLimit(1)
                resendButton(item, title: "Retry", tint: Theme.warn)
            }

        case .skipped(let why):
            HStack(spacing: 8) {
                Text(why)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                if why == "cancelled" {
                    resendButton(item, title: "Send", tint: Theme.accent)
                }
            }

        case .done:
            resendButton(item, title: "Send again", tint: Theme.textFaint)

        case .waiting:
            EmptyView()
        }
    }

    @ViewBuilder
    private func resendButton(_ item: TransferItem, title: String, tint: Color) -> some View {
        if !transfer.isRunning, let onResend {
            Button(title) { onResend(item) }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14))
                .clipShape(Capsule())
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func icon(for state: TransferItem.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(Theme.textFaint.opacity(0.5))
        case .copying:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textFaint)
        }
    }
}

import SwiftUI

/// Live aggregate-throughput sparkline (HyperDM `speed_graph`). A ring buffer
/// of recent `aggregateSpeed` samples is kept by `DownloadStore`; this view draws
/// it as a thin accent line so the user can eyeball sustained vs bursty traffic.
struct SpeedGraphView: View {
    @EnvironmentObject private var store: DownloadStore

    private static let sampleCount = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("总速度 \(Formatting.speed(store.aggregateSpeed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let peak = store.speedHistory.max(), peak > 0 {
                    Text("峰值 \(Formatting.speed(peak))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Canvas { ctx, size in
                let data = store.speedHistory
                guard data.count > 1 else { return }
                let peak = max(data.max() ?? 1, 1)
                let w = size.width
                let h = size.height
                var path = Path()
                let step = w / CGFloat(data.count - 1)
                for (i, v) in data.enumerated() {
                    let x = CGFloat(i) * step
                    // Leave a 1px floor so a zero sample stays visible at the base.
                    let y = h - max(1, CGFloat(v) / CGFloat(peak) * (h - 1))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

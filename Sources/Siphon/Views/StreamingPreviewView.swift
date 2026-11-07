import SwiftUI
import AVKit

/// Play a task straight from the loopback preview server while its bytes are
/// still arriving. Finished files should use the system default app instead.
struct StreamingPreviewView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: DownloadTask

    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.headline).lineLimit(1)
                    Text(task.state.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("关闭预览")
            }
            .padding(12)
            Divider()
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .background(Color.black)
                } else if let error {
                    ContentUnavailableView {
                        Label("无法播放", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else {
                    ProgressView("准备边下边播…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .task { open() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func open() {
        guard let url = store.previewURL(for: task) else {
            error = store.lastError ?? "无法创建预览地址"
            return
        }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        avPlayer.play()
    }
}

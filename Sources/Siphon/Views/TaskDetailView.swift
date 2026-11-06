import SwiftUI
import AppKit

/// Inspector column: an opaque grouped form. The inspector sits beside the
/// system's glass sidebar, so adding another custom glass surface here would
/// double-composite; header, rows and numbers stay plain and crisp.
struct TaskDetailView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask

    var body: some View {
        VStack(spacing: 0) {
            identityCard
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            Form {
                Section("进度") {
                    LabeledContent("状态", value: task.state.displayName)
                    ProgressView(value: task.progress.percent)
                    LabeledContent("已完成", value: Formatting.percent(task.progress.percent))
                    LabeledContent("大小", value: "\(Formatting.bytes(task.progress.downloadedBytes)) / \(Formatting.bytes(task.progress.totalBytes))")
                    LabeledContent("速度", value: Formatting.speed(task.progress.speedBytesPerSec))
                    LabeledContent("剩余时间", value: Formatting.eta(downloaded: task.progress.downloadedBytes,
                                                                 total: task.progress.totalBytes,
                                                                 speed: task.progress.speedBytesPerSec))
                    if task.progress.connectedPeers > 0 {
                        LabeledContent("连接数", value: "\(task.progress.connectedPeers)")
                    }
                }

                Section("任务信息") {
                    LabeledContent("队列", value: task.queueName)
                    LabeledContent("引擎", value: task.protocol.transport.displayName)
                    LabeledContent("创建时间", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("来源（规范化后）").font(.caption).foregroundStyle(.secondary)
                        Text(task.source.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    if let origin = task.origin, origin != task.source.absoluteString {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原始链接").font(.caption).foregroundStyle(.secondary)
                            Text(origin)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标").font(.caption).foregroundStyle(.secondary)
                        Text(task.destination.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if let e = task.errorDescription {
                        Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 280)
        // No nested toolbar: a second .toolbar here injects an ungrouped item
        // into the window's unified toolbar. "在访达中显示所选文件" lives in
        // ContentView's More menu instead.
    }

    private var identityCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ProtocolBadge(proto: task.protocol)
                        Text(task.state.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

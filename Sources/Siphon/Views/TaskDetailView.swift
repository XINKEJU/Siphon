import SwiftUI
import AppKit

/// Inspector column for the selected task: progress, transfer stats, and metadata.
struct TaskDetailView: View {
    @EnvironmentObject private var store: DownloadStore
    let task: DownloadTask

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(task.name).font(.headline).lineLimit(2)
                        LabeledContent("协议", value: task.protocol.displayName)
                    }
                }
            }

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
                LabeledContent("引擎", value: task.protocol.requiresAria2 ? "aria2 (JSON-RPC)" : "Swift 原生引擎")
                LabeledContent("创建时间", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源").font(.caption).foregroundStyle(.secondary)
                    Text(task.source.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
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
        .frame(minWidth: 280)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([task.destination])
                }
                .disabled(!FileManager.default.fileExists(atPath: task.destination.path))
            }
        }
    }
}

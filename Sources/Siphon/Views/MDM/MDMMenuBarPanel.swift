import SwiftUI
import AppKit

/// Status-item popover: the compact surface people reach for without pulling
/// the main window forward. Left-click opens this; right-click keeps the
/// traditional menu (pause all / settings / quit).
struct MDMMenuBarPanelView: View {
    @Environment(DownloadStore.self) private var store
    @ObservedObject private var theme = MDMThemeStore.shared
    let onOpenMain: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var recent: [DownloadTask] {
        Array(store.tasks.sorted { $0.createdAt > $1.createdAt }.prefix(8))
    }

    private var activeCount: Int {
        store.tasks.filter { $0.state == .active }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(recent) { task in
                            row(task)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 340, height: 420)
        .background(theme.color(.surface))
        .foregroundStyle(theme.color(.text))
        .dynamicTypeSize(theme.dynamicTypeSize)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(theme.font(size: 20))
                .foregroundStyle(activeCount > 0 ? Color.accentColor : theme.color(.secondaryText))
            VStack(alignment: .leading, spacing: 1) {
                Text("Siphon 下载").font(theme.font(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(theme.font(size: 10))
                    .foregroundStyle(theme.color(.secondaryText))
            }
            Spacer()
            Text(Formatting.speed(store.aggregateSpeed))
                .font(theme.monoFont(size: 13, weight: .semibold))
                .foregroundStyle(theme.color(.text))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var subtitle: String {
        let pending = store.tasks.filter { $0.state == .pending || $0.state == .paused }.count
        if activeCount > 0 {
            return pending > 0 ? "\(activeCount) 个进行中 · \(pending) 个等待" : "\(activeCount) 个进行中"
        }
        return pending > 0 ? "\(pending) 个等待" : "空闲"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(theme.font(size: 28))
                .foregroundStyle(theme.color(.secondaryText))
            Text("还没有下载任务").font(theme.font(size: 12))
            Text("从浏览器接管或拖入链接后会出现在这里。")
                .font(theme.font(size: 10))
                .foregroundStyle(theme.color(.secondaryText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ task: DownloadTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(task))
                .font(theme.font(size: 11))
                .foregroundStyle(tint(task))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(theme.font(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(task.state.displayName)
                    Text(progressText(task))
                    Spacer(minLength: 4)
                    if task.state == .active {
                        Text(Formatting.speed(task.progress.speedBytesPerSec))
                            .monospacedDigit()
                    }
                }
                .font(theme.font(size: 10))
                .foregroundStyle(theme.color(.secondaryText))
                .lineLimit(1)

                if task.progress.totalBytes > 0 {
                    ProgressView(value: task.progress.percent)
                        .progressViewStyle(.linear)
                        .tint(theme.color(.progressBar))
                        .controlSize(.small)
                }
            }

            if canPause(task) || canResume(task) {
                Button {
                    if canPause(task) { store.pause(task.id) } else { store.resume(task.id) }
                } label: {
                    Image(systemName: canPause(task) ? "pause.fill" : "play.fill")
                        .font(theme.font(size: 10))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color(.secondaryText))
                .help(canPause(task) ? "暂停" : "继续")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let hasActive = store.tasks.contains { $0.state == .active || $0.state == .pending }
            Button {
                if hasActive { store.pauseAll() } else { store.resumeAll() }
            } label: {
                Label(hasActive ? "全部暂停" : "全部恢复",
                      systemImage: hasActive ? "pause.circle" : "play.circle")
            }
            .disabled(store.tasks.isEmpty)

            Spacer(minLength: 4)

            Button { onOpenMain() } label: {
                Label("主窗口", systemImage: "macwindow")
            }
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("偏好设置")
            Button { onQuit() } label: {
                Image(systemName: "power")
            }
            .help("退出 Siphon")
        }
        .font(theme.font(size: 11))
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: - Helpers

    private func progressText(_ task: DownloadTask) -> String {
        if task.progress.totalBytes > 0 {
            return "\(Formatting.percent(task.progress.percent)) · "
                + "\(Formatting.bytes(task.progress.downloadedBytes))"
        }
        return Formatting.bytes(task.progress.downloadedBytes)
    }

    private func canPause(_ task: DownloadTask) -> Bool {
        task.state == .active || task.state == .pending
    }

    private func canResume(_ task: DownloadTask) -> Bool {
        task.state == .paused || task.state == .error
    }

    private func icon(_ task: DownloadTask) -> String {
        switch task.state {
        case .active: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "clock.circle"
        }
    }

    private func tint(_ task: DownloadTask) -> Color {
        switch task.state {
        case .active: return .accentColor
        case .completed: return theme.color(.success)
        case .error: return theme.color(.error)
        case .paused: return theme.color(.warning)
        default: return theme.color(.secondaryText)
        }
    }
}
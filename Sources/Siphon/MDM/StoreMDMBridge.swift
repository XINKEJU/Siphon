import Foundation

/// Adapters between MDM's single command contract and Siphon's store.
/// Keeping them in one file means REST, MCP, extension and UI dialogs all
/// converge on the same behaviour for `later`, `silent`, `category` and the
/// no-paths规则 used by the remote page.
extension DownloadStore {
    public func mdmListAnswer() -> MDMListAnswer {
        let speed = tasks.reduce(Int64(0)) { $0 + $1.progress.speedBytesPerSec }
        var free: Int64?
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: downloadDirectory.path),
           let value = attrs[.systemFreeSize] as? NSNumber {
            free = value.int64Value
        }
        return MDMListAnswer(
            downloads: tasks.map { MDMDownloadInfo($0) },
            speed: speed,
            queues: queues.queues.map(\.name),
            categories: MDMCategory.allCases.filter(\.isRoot).map(\.rawValue),
            free: free
        )
    }

    /// Remote/popup view: strips local paths and credentials by construction.
    public func mdmRecentAnswer(limit: Int = 60) -> MDMRecentAnswer {
        let recent = tasks
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { MDMDownloadInfo($0) }
        return MDMRecentAnswer(recent: Array(recent))
    }

    @MainActor
    public func addMDMCommand(_ command: MDMCommand) async -> MDMAddAnswer {
        guard let raw = command.url, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MDMAddAnswer(ok: false, note: "missing url")
        }
        var options: [String: String] = [:]
        if let referer = command.referer { options["Referer"] = referer }
        if let userAgent = command.userAgent { options["User-Agent"] = userAgent }
        if let mime = command.mime { options["Expected-Content-Type"] = mime }
        if let cookies = command.cookies, !cookies.isEmpty {
            options["Cookie"] = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
        if let post = command.post { options["PostData"] = post }

        let before = Set(tasks.map(\.id))
        await addNormalized(urlString: raw,
                            name: command.name,
                            queueName: command.queue ?? "Default",
                            options: options,
                            checksum: command.checksum)

        let created = tasks.first { !before.contains($0.id) }
        if command.later == true, let created {
            pause(created.id)
        }
        if let queueToStart = command.startQueue, !queueToStart.isEmpty {
            // MDM sends the queue name; Siphon currently exposes a single
            // active queue, so any non-empty name resumes all queued tasks.
            resumeAll()
        }
        return MDMAddAnswer(ok: created != nil || tasks.contains(where: {
            $0.source.absoluteString == raw
        }), id: created?.id.uuidString, note: created == nil ? "duplicate or unresolved" : nil)
    }

    public func performMDMAction(_ action: String, ids: [String]?) {
        let wanted = Set((ids ?? []).compactMap { UUID(uuidString: $0) })
        switch action {
        case "pause": pauseTasks(wanted.isEmpty ? Set(tasks.map(\.id)) : wanted)
        case "start", "resume": resumeTasks(wanted.isEmpty ? Set(tasks.map(\.id)) : wanted)
        case "remove": removeTasks(wanted)
        case "delete": deleteTasks(wanted)
        case "start_queue": resumeAll()
        case "stop_queue": pauseAll()
        default: break
        }
    }
}

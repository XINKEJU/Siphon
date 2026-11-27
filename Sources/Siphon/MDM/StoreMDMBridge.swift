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
        if let post = command.post {
            options["PostData"] = post
            if let type = command.postType, !type.isEmpty {
                options["PostContentType"] = type
            }
        }
        // Internal hand-off context. `Siphon.*` keys are stripped before the
        // request is built, so none of these ever leak as HTTP headers.
        if let finalUrl = command.finalUrl, !finalUrl.isEmpty {
            options["Siphon.FinalURL"] = finalUrl
        }
        if let size = command.size, size > 0 {
            options["Siphon.ExpectedSize"] = String(size)
        }
        if let proxy = command.proxy, !proxy.isEmpty {
            options["Siphon.Proxy"] = proxy
        }
        if let pac = command.proxyPac, !pac.isEmpty {
            options["Siphon.ProxyPac"] = pac
        }
        if command.privateWindow == true {
            options["Siphon.Private"] = "1"
        }

        let directory = command.dir.flatMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        let category = command.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = command.description?.trimmingCharacters(in: .whitespacesAndNewlines)

        let before = Set(tasks.map(\.id))
        await addNormalized(urlString: raw,
                            name: command.name,
                            queueName: command.queue ?? "Default",
                            options: options,
                            checksum: command.checksum,
                            category: category?.isEmpty == false ? category : nil,
                            note: note?.isEmpty == false ? note : nil,
                            directory: directory)

        let created = tasks.first { !before.contains($0.id) }
        // The browser already knows the size and type; show them immediately
        // instead of waiting for our own probe (MDM's Download File Info).
        if let created, let size = command.size, size > 0,
           let index = tasks.firstIndex(where: { $0.id == created.id }),
           tasks[index].progress.totalBytes == 0 {
            tasks[index].progress.totalBytes = size
        }
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

    /// A flat hand-off from the browser extension (`POST /browser/add`).
    ///
    /// MDM's wire form is camelCase and carries the browser's own context:
    /// `referrer`/`pageUrl`, `cookies`/`cookieJar`, `userAgent`, `filename`
    /// (plus `nameGuessed`), `finalUrl`, `size`, `mime`, `post`/`postType`,
    /// `private`, `proxy`/`proxyPac`. This maps the fields the engines already
    /// understand onto the same `MDMCommand` that remote clients use, so a
    /// browser download and a remote add take one code path.
    ///
    /// Returns immediately: the browser cancels its own copy once we answer ok,
    /// exactly as the legacy `/add` path has always behaved.
    public func mdmBrowserAdd(_ json: [String: Any]) -> [String: Any] {
        guard let raw = (json["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ["ok": false, "error": "missing url"]
        }
        var command = MDMCommand(url: raw)
        command.referer = (json["referrer"] as? String) ?? (json["pageUrl"] as? String)
        command.pageUrl = json["pageUrl"] as? String
        command.userAgent = json["userAgent"] as? String
        command.mime = json["mime"] as? String
        command.post = json["post"] as? String
        command.postType = json["postType"] as? String
        command.finalUrl = json["finalUrl"] as? String
        command.proxy = json["proxy"] as? String
        command.proxyPac = json["proxyPac"] as? String
        command.size = (json["size"] as? NSNumber)?.int64Value
        command.privateWindow = json["private"] as? Bool
        command.browserHandoff = true
        // A guessed name is only the address's last segment; the app names the
        // file from the server's answer in that case, as with no name at all.
        if json["nameGuessed"] as? Bool != true {
            command.name = json["filename"] as? String
        }
        command.cookies = Self.cookieDictionary(from: json)

        Task { _ = await self.addMDMCommand(command) }
        return ["ok": true]
    }

    /// `cookieJar` (domains and flags) wins over the flat `cookies` header
    /// string: the jar is what the browser actually sent for this request.
    private static func cookieDictionary(from json: [String: Any]) -> [String: String]? {
        if let jar = json["cookieJar"] as? [[String: Any]], !jar.isEmpty {
            var out: [String: String] = [:]
            for item in jar {
                guard let name = item["name"] as? String, !name.isEmpty,
                      let value = item["value"] as? String else { continue }
                out[name] = value
            }
            if !out.isEmpty { return out }
        }
        if let raw = json["cookies"] as? String, !raw.isEmpty {
            var out: [String: String] = [:]
            for pair in raw.split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eq])
                let value = String(trimmed[trimmed.index(after: eq)...])
                if !name.isEmpty { out[name] = value }
            }
            if !out.isEmpty { return out }
        }
        return nil
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

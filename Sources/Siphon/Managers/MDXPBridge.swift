import Foundation

/// The store-backed operations the MDXP bridge can call. Kept as a protocol so
/// the JSON-RPC layer is testable without a live `DownloadStore`.
public protocol MDXPBackend: AnyObject {
    /// Snapshot of every task (`tasks.list`).
    func mdxpTasks() -> [[String: Any]]
    /// One task by id (`tasks.get`); nil when the id is unknown.
    func mdxpTask(id: String) -> [String: Any]?
    /// Enqueue a download (`tasks.add`). Returns false on an unusable URL.
    func mdxpAdd(url: String, name: String?, queue: String?, priority: Int?,
                 headers: [String: String]?) -> Bool
    func mdxpPause(id: String) -> Bool
    func mdxpResume(id: String) -> Bool
    func mdxpRemove(id: String) -> Bool
    func mdxpSetPriority(id: String, priority: Int) -> Bool
    /// Current configuration (`config.get`).
    func mdxpConfig() -> [String: Any]
}

/// Minimal MDXP bridge: JSON-RPC 2.0 over the loopback control port.
///
/// MDXP clients (remote devices paired through `RemotePairing`) speak the same
/// request/response framing as MCP but use a device token instead of the local
/// API token. This type is pure Foundation — no network, no store reference —
/// so its dispatch and error codes can be verified offline.
///
/// Methods:
/// - `mdxp.ping`
/// - `tasks.list` / `tasks.get`
/// - `tasks.add` (url, name?, queue?, priority?, headers?)
/// - `tasks.pause` / `tasks.resume` / `tasks.remove` / `tasks.priority`
/// - `config.get`
public final class MDXPBridge {
    public var backend: (any MDXPBackend)?

    public init(backend: (any MDXPBackend)? = nil) {
        self.backend = backend
    }

    private enum RPCError {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let serverError = -32603
        static let taskNotFound = -32004
    }

    /// Handle one JSON-RPC request body and return a JSON-RPC response body.
    public func handle(_ body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return errorResponse(id: NSNull(), code: RPCError.parse, message: "JSON 解析失败")
        }
        guard let request = object as? [String: Any] else {
            return errorResponse(id: NSNull(), code: RPCError.invalidRequest,
                                 message: "请求必须是 JSON 对象")
        }
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String, !method.isEmpty else {
            return errorResponse(id: id, code: RPCError.invalidRequest,
                                 message: "缺少 jsonrpc/method")
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "mdxp.ping":
            return resultResponse(id: id, result: [
                "ok": true, "app": "Siphon", "protocol": "mdxp/1"
            ])

        case "tasks.list":
            guard let backend else { return backendMissing(id) }
            return resultResponse(id: id, result: backend.mdxpTasks())

        case "tasks.get":
            guard let backend else { return backendMissing(id) }
            guard let taskID = params["id"] as? String, !taskID.isEmpty else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "缺少任务 id")
            }
            guard let task = backend.mdxpTask(id: taskID) else {
                return errorResponse(id: id, code: RPCError.taskNotFound,
                                     message: "任务不存在")
            }
            return resultResponse(id: id, result: task)

        case "tasks.add":
            guard let backend else { return backendMissing(id) }
            guard let url = params["url"] as? String, !url.isEmpty,
                  URL(string: url)?.scheme != nil else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "缺少合法 url")
            }
            let name = (params["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let queue = (params["queue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let priority = (params["priority"] as? NSNumber)?.intValue
            let headers = params["headers"] as? [String: String]
            guard backend.mdxpAdd(url: url, name: name, queue: queue,
                                  priority: priority, headers: headers) else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "无法加入下载队列")
            }
            return resultResponse(id: id, result: ["ok": true])

        case "tasks.pause", "tasks.resume", "tasks.remove":
            guard let backend else { return backendMissing(id) }
            guard let taskID = params["id"] as? String, !taskID.isEmpty else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "缺少任务 id")
            }
            let ok: Bool
            switch method {
            case "tasks.pause": ok = backend.mdxpPause(id: taskID)
            case "tasks.resume": ok = backend.mdxpResume(id: taskID)
            default: ok = backend.mdxpRemove(id: taskID)
            }
            guard ok else {
                return errorResponse(id: id, code: RPCError.taskNotFound,
                                     message: "任务不存在")
            }
            return resultResponse(id: id, result: ["ok": true])

        case "tasks.priority":
            guard let backend else { return backendMissing(id) }
            guard let taskID = params["id"] as? String, !taskID.isEmpty else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "缺少任务 id")
            }
            guard let priority = (params["priority"] as? NSNumber)?.intValue else {
                return errorResponse(id: id, code: RPCError.invalidParams,
                                     message: "缺少 priority（整数）")
            }
            guard backend.mdxpSetPriority(id: taskID, priority: priority) else {
                return errorResponse(id: id, code: RPCError.taskNotFound,
                                     message: "任务不存在")
            }
            return resultResponse(id: id, result: ["ok": true])

        case "config.get":
            guard let backend else { return backendMissing(id) }
            return resultResponse(id: id, result: backend.mdxpConfig())

        default:
            return errorResponse(id: id, code: RPCError.methodNotFound,
                                 message: "未知方法：\(method)")
        }
    }

    private func backendMissing(_ id: Any) -> Data {
        errorResponse(id: id, code: RPCError.serverError, message: "后端未连接")
    }

    private func resultResponse(id: Any, result: Any) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorResponse(id: Any, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id,
                "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"编码失败"}}"#.utf8)
    }
}

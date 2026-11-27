import Foundation

/// Siphon command-line interface. Talks to the loopback Automation API; never
/// touches tasks.json directly. Stable exit codes: 0 success, 1 usage error,
/// 2 connection failure, 3 API error, 4 authentication failure.
struct SiphonCLI {
    static let endpoint = URL(string: "http://127.0.0.1:17801")!
    static let token = ProcessInfo.processInfo.environment["SIPHON_TOKEN"] ?? ""

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "add":
                try await add(Array(args.dropFirst()))
            case "list":
                try await list(Array(args.dropFirst()))
            case "pause", "resume":
                try await action(command, Array(args.dropFirst()))
            case "pause-all":
                try await simple("pause-all")
            case "resume-all":
                try await simple("resume-all")
            case "remove-completed":
                try await simple("remove-completed")
            case "queues":
                try await printJSON("/queues")
            case "config":
                try await printJSON("/config")
            case "remove", "delete":
                try await action(command, Array(args.dropFirst()))
            case "start-queue":
                try await queue("start_queue", Array(args.dropFirst()))
            case "stop-queue":
                try await queue("stop_queue", Array(args.dropFirst()))
            case "schema":
                try await schema()
            case "--version", "-v":
                print("Siphon CLI 0.5.0")
            default:
                print("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch CLIError.connection {
            FileHandle.standardError.write("error: cannot connect to Siphon. Is the app running?\n".data(using: .utf8)!)
            exit(2)
        } catch CLIError.auth {
            FileHandle.standardError.write("error: unauthorized. Set SIPHON_TOKEN or check Settings → Integration.\n".data(using: .utf8)!)
            exit(4)
        } catch CLIError.api(let msg) {
            FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
            exit(3)
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(3)
        }
    }

    static func printUsage() {
        print("""
        Siphon CLI — manage downloads from the terminal

        Usage: siphon <command> [options]

        Commands:
          add <url> [--name <name>] [--dir <path>] [--category <cat>] [--queue <q>] [--later]
          list [--state <state>] [--queue <q>] [--category <cat>] [--query <text>] [--json]
          pause <id>
          resume <id>
          pause-all
          resume-all
          remove <id>
          delete <id>
          remove-completed
          start-queue
          stop-queue
          queues
          config
          schema
          --version

        Environment:
          SIPHON_TOKEN   Loopback API token (Settings → Integration)
        """)
    }

    // MARK: - Commands

    static func add(_ args: [String]) async throws {
        guard let url = args.first else {
            FileHandle.standardError.write("error: missing url\n".data(using: .utf8)!)
            exit(1)
        }
        var payload: [String: Any] = ["url": url]
        var rest = Array(args.dropFirst())
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            switch flag {
            case "--name": payload["name"] = rest.removeFirst()
            case "--dir": payload["dir"] = rest.removeFirst()
            case "--category": payload["category"] = rest.removeFirst()
            case "--queue": payload["queue"] = rest.removeFirst()
            case "--later": payload["later"] = true
            default: break
            }
        }
        let result = try await post("/add", payload)
        if let id = result["id"] as? String {
            print("ok: added \(id)")
        } else {
            print("ok: added")
        }
    }

    static func list(_ args: [String]) async throws {
        var query: [String: Any] = [:]
        var rest = args
        var jsonOutput = false
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            switch flag {
            case "--state": query["state"] = rest.removeFirst()
            case "--queue": query["queue"] = rest.removeFirst()
            case "--category": query["category"] = rest.removeFirst()
            case "--query": query["query"] = rest.removeFirst()
            case "--json": jsonOutput = true
            default: break
            }
        }
        let result = try await get("/tasks", query: query)
        if jsonOutput {
            let data = try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard let tasks = result["tasks"] as? [[String: Any]] else {
            print("no tasks")
            return
        }
        for t in tasks {
            let id = t["id"] as? String ?? ""
            let name = t["name"] as? String ?? ""
            let state = t["state"] as? String ?? ""
            let downloaded = t["downloaded"] as? Int64 ?? 0
            let total = t["total"] as? Int64 ?? 0
            print("\(id) [\(state)] \(name) (\(formatBytes(downloaded))/\(formatBytes(total)))")
        }
    }

    static func action(_ name: String, _ args: [String]) async throws {
        guard let id = args.first else {
            FileHandle.standardError.write("error: missing task id\n".data(using: .utf8)!)
            exit(1)
        }
        _ = try await post("/\(name)", ["id": id])
        print("ok")
    }

    /// A POST that needs no arguments (pause-all, remove-completed, …).
    static func simple(_ path: String) async throws {
        _ = try await post("/\(path)", [:])
        print("ok")
    }

    static func printJSON(_ path: String) async throws {
        let result = try await get(path)
        let data = try JSONSerialization.data(withJSONObject: result,
                                              options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func queue(_ action: String, _ args: [String]) async throws {
        var payload: [String: Any] = ["action": action]
        if let name = args.first, !name.isEmpty { payload["name"] = name }
        _ = try await post("/queue", payload)
        print("ok")
    }

    static func schema() async throws {
        let result = try await get("/schema")
        let data = try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    // MARK: - HTTP

    static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    static func get(_ path: String, query: [String: Any] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }
        var req = URLRequest(url: comps.url!)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await send(req)
    }

    static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CLIError.connection
        }
        guard let http = response as? HTTPURLResponse else { throw CLIError.connection }
        if http.statusCode == 401 { throw CLIError.auth }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.api("invalid response")
        }
        if http.statusCode >= 400 {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                ?? obj["note"] as? String ?? "HTTP \(http.statusCode)"
            throw CLIError.api(msg)
        }
        return obj
    }

    static func formatBytes(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n), i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: "%.1f %@", value, units[i])
    }

    enum CLIError: Error {
        case connection, auth, api(String)
    }
}

@main
struct SiphonCLIMain {
    static func main() async {
        await SiphonCLI.main()
    }
}

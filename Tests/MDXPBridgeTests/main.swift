import Foundation

// MDXP JSON-RPC bridge tests: dispatch, error codes, params, and id echo,
// exercised against a fake backend (no store, no network).

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

final class FakeBackend: MDXPBackend {
    var addedPriority: Int?
    var addedQueue: String?
    var addedHeaders: [String: String]?
    var prioritized: [(String, Int)] = []

    func mdxpTasks() -> [[String: Any]] {
        [["id": "t1", "name": "file.bin", "priority": 1]]
    }

    func mdxpTask(id: String) -> [String: Any]? {
        id == "t1" ? ["id": "t1", "name": "file.bin", "priority": 1] : nil
    }

    func mdxpAdd(url: String, name: String?, queue: String?, priority: Int?,
                 headers: [String: String]?) -> Bool {
        addedPriority = priority
        addedQueue = queue
        addedHeaders = headers
        return url.hasPrefix("https://")
    }

    func mdxpPause(id: String) -> Bool { id == "t1" }
    func mdxpResume(id: String) -> Bool { id == "t1" }
    func mdxpRemove(id: String) -> Bool { id == "t1" }

    func mdxpSetPriority(id: String, priority: Int) -> Bool {
        guard id == "t1" else { return false }
        prioritized.append((id, priority))
        return true
    }

    func mdxpConfig() -> [String: Any] {
        ["downloadDirectory": "/tmp", "globalConcurrent": 5]
    }
}

let backend = FakeBackend()
let bridge = MDXPBridge(backend: backend)

func rpc(_ json: String) -> [String: Any] {
    let out = bridge.handle(Data(json.utf8))
    return (try? JSONSerialization.jsonObject(with: out) as? [String: Any]) ?? [:]
}

func errorCode(_ response: [String: Any]) -> Int? {
    (response["error"] as? [String: Any])?["code"] as? Int
}

// 1. ping
let ping = rpc(#"{"jsonrpc":"2.0","id":1,"method":"mdxp.ping"}"#)
check(ping["jsonrpc"] as? String == "2.0", "ping: jsonrpc version echoed")
check(ping["id"] as? Int == 1, "ping: numeric id echoed")
check((ping["result"] as? [String: Any])?["app"] as? String == "Siphon", "ping: app name")

// 2. list / get
let list = rpc(#"{"jsonrpc":"2.0","id":"a","method":"tasks.list"}"#)
check((list["result"] as? [[String: Any]])?.count == 1, "tasks.list returns task array")
let get = rpc(#"{"jsonrpc":"2.0","id":2,"method":"tasks.get","params":{"id":"t1"}}"#)
check((get["result"] as? [String: Any])?["name"] as? String == "file.bin", "tasks.get returns task")
let missing = rpc(#"{"jsonrpc":"2.0","id":3,"method":"tasks.get","params":{"id":"nope"}}"#)
check(errorCode(missing) == -32004, "tasks.get unknown id → -32004")

// 3. add
let badAdd = rpc(#"{"jsonrpc":"2.0","id":4,"method":"tasks.add","params":{}}"#)
check(errorCode(badAdd) == -32602, "tasks.add without url → -32602")
let add = rpc(#"{"jsonrpc":"2.0","id":5,"method":"tasks.add","params":{"url":"https://example.com/a.bin","queue":"Fast","priority":1,"headers":{"Referer":"https://example.com/"}}}"#)
check((add["result"] as? [String: Any])?["ok"] as? Bool == true, "tasks.add accepted")
check(backend.addedPriority == 1 && backend.addedQueue == "Fast", "add priority/queue forwarded")
check(backend.addedHeaders?["Referer"] == "https://example.com/", "add headers forwarded")

// 4. control
let pause = rpc(#"{"jsonrpc":"2.0","id":6,"method":"tasks.pause","params":{"id":"t1"}}"#)
check((pause["result"] as? [String: Any])?["ok"] as? Bool == true, "tasks.pause ok")
let pauseMissing = rpc(#"{"jsonrpc":"2.0","id":7,"method":"tasks.pause","params":{"id":"zzz"}}"#)
check(errorCode(pauseMissing) == -32004, "tasks.pause unknown id → -32004")
let priorityMissing = rpc(#"{"jsonrpc":"2.0","id":8,"method":"tasks.priority","params":{"id":"t1"}}"#)
check(errorCode(priorityMissing) == -32602, "tasks.priority missing value → -32602")
let priority = rpc(#"{"jsonrpc":"2.0","id":9,"method":"tasks.priority","params":{"id":"t1","priority":-1}}"#)
check((priority["result"] as? [String: Any])?["ok"] as? Bool == true, "tasks.priority ok")
check(backend.prioritized.last?.1 == -1, "priority value forwarded")

// 5. config
let config = rpc(#"{"jsonrpc":"2.0","id":10,"method":"config.get"}"#)
check((config["result"] as? [String: Any])?["globalConcurrent"] as? Int == 5,
      "config.get returns backend config")

// 6. errors
check(errorCode(rpc(#"{"jsonrpc":"2.0","id":11,"method":"nope"}"#)) == -32601,
      "unknown method → -32601")
check(errorCode(rpc(#"{"jsonrpc":"2.0","id":12}"#)) == -32600,
      "missing method → -32600")
check(errorCode(rpc(#"{"jsonrpc":"2.0","id":13,"method":"tasks.list"}"#)) == nil,
      "no backend error in normal path")
let parse = rpc("this is not json")
check(errorCode(parse) == -32700, "malformed JSON → -32700")
check(parse["id"] is NSNull, "parse error id is null")

// 7. null backend
bridge.backend = nil
let noBackend = rpc(#"{"jsonrpc":"2.0","id":14,"method":"tasks.list"}"#)
check(errorCode(noBackend) == -32603, "missing backend → -32603")

if failures == 0 { print("MDXP BRIDGE TESTS PASSED") }
else { print("MDXP BRIDGE TESTS FAILED: \(failures)"); exit(1) }

import Foundation

// Real end-to-end test of the aria2 integration:
// launch bundled/PATH aria2c -> JSON-RPC getGlobalStat -> addUri -> download
// from the local fixture server -> verify bytes -> stop the process.
// Only runs when aria2c is available (scripts/verify.sh skips it otherwise).

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let bootstrap = Aria2Bootstrap.shared
// Session persistence is tested below; isolate the session file so tests never
// read or clobber the real app's session.
let sessionPath = NSTemporaryDirectory() + "siphon-aria2-session-\(UUID().uuidString).a2"
bootstrap.sessionFile = URL(fileURLWithPath: sessionPath)
do {
    try await bootstrap.start()
    check("aria2c launched", bootstrap.isRunning)
} catch {
    print("FAIL  aria2c launch: \(error)")
    exit(1)
}

let rpc = Aria2RPC(endpoint: bootstrap.rpcURL, secret: bootstrap.rpcSecret)
check("rpc secret generated", !bootstrap.rpcSecret.isEmpty)
do {
    let stat = try await rpc.getGlobalStat()
    check("getGlobalStat RPC (with secret)", stat["numActive"] != nil, "\(stat)")
} catch {
    print("FAIL  getGlobalStat: \(error)")
    bootstrap.stop()
    exit(1)
}

// An unauthenticated client must be rejected now that --rpc-secret is set —
// this is the drive-by protection itself, not just plumbing.
do {
    let rogue = Aria2RPC(endpoint: bootstrap.rpcURL)
    _ = try await rogue.getGlobalStat()
    check("unauthenticated RPC rejected", false, "call succeeded without token")
} catch {
    check("unauthenticated RPC rejected", true)
}

let url = "http://127.0.0.1:18766/file.bin"
let destDir = NSTemporaryDirectory() + "siphon-aria2-e2e"
try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(atPath: destDir + "/file.bin")

do {
    let gid = try await rpc.addUri(url, options: ["dir": destDir, "out": "file.bin"])
    check("addUri returned GID", !gid.isEmpty, gid)

    var completed = false
    for _ in 0..<60 {
        let stopped = try await rpc.tellStopped()
        if let s = stopped.first(where: { ($0["gid"] as? String) == gid }),
           (s["status"] as? String) == "complete" { completed = true; break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    check("aria2 reported complete", completed)

    let text = (try? Data(contentsOf: URL(fileURLWithPath: destDir + "/file.bin")))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
    check("downloaded bytes correct", text == "Siphon-RPC-E2E-OK", text)
    _ = try? await rpc.remove(gid)
} catch {
    print("FAIL  download: \(error)"); failures += 1
}

// MARK: - session persistence across restart (save on shutdown, reload + adopt)

let magnet = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000" +
             "&dn=siphon-session-test&tr=udp%3A%2F%2F127.0.0.1%3A1%2Fannounce"
do {
    let sid = try await rpc.addUri(magnet)
    check("session magnet added", !sid.isEmpty, sid)

    bootstrap.stop()   // SIGTERM → graceful shutdown → session file written
    let saved = (try? String(contentsOfFile: sessionPath, encoding: .utf8)) ?? ""
    check("session file written on shutdown", saved.contains(sid), saved)

    try await bootstrap.start()   // reloads the session via --input-file
    check("aria2 relaunched", bootstrap.isRunning)
    let engine = Aria2Engine(endpoint: bootstrap.rpcURL, secret: bootstrap.rpcSecret)
    let taskID = UUID()
    let adopted = await engine.adoptPersistedSessions([taskID: magnet])
    check("persisted download adopted by URI match", adopted == [taskID], "\(adopted)")

    let all = ((try? await rpc.tellActive()) ?? [])
        + ((try? await rpc.tellWaiting()) ?? [])
        + ((try? await rpc.tellStopped()) ?? [])
    let mine = all.filter { ($0["gid"] as? String) == sid }
    check("reloaded exactly once (no duplicate submit)", mine.count == 1, "\(mine.count)")
    check("reloaded download force-paused", (mine.first?["status"] as? String) == "paused",
          "\(mine.first?["status"] ?? "nil")")

    // Resume through the adopted GID binding — exactly what schedule() does for
    // a restored task the user re-starts.
    await engine.resume(taskID)
    var unpaused = false
    for _ in 0..<40 {
        let live = ((try? await rpc.tellActive()) ?? []) + ((try? await rpc.tellWaiting()) ?? [])
        let st = live.first(where: { ($0["gid"] as? String) == sid })?["status"] as? String
        if st != nil && st != "paused" { unpaused = true; break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    check("resume through adopted GID unpauses", unpaused)
    try? await rpc.forceRemove(sid)
} catch {
    print("FAIL  session persistence: \(error)"); failures += 1
}

bootstrap.stop()
check("aria2c stopped", !bootstrap.isRunning)
try? FileManager.default.removeItem(atPath: sessionPath)
try? FileManager.default.removeItem(atPath: destDir)

print(failures == 0 ? "Aria2RPCTests: ALL PASS" : "Aria2RPCTests: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

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
do {
    try await bootstrap.start()
    check("aria2c launched", bootstrap.isRunning)
} catch {
    print("FAIL  aria2c launch: \(error)")
    exit(1)
}

let rpc = Aria2RPC(endpoint: bootstrap.rpcURL)
do {
    let stat = try await rpc.getGlobalStat()
    check("getGlobalStat RPC", stat["numActive"] != nil, "\(stat)")
} catch {
    print("FAIL  getGlobalStat: \(error)")
    bootstrap.stop()
    exit(1)
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

bootstrap.stop()
check("aria2c stopped", !bootstrap.isRunning)
try? FileManager.default.removeItem(atPath: destDir)

print(failures == 0 ? "Aria2RPCTests: ALL PASS" : "Aria2RPCTests: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

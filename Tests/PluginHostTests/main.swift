import Foundation

// PluginHost tests: manifest loading, wildcard matching, JS resolve, sandbox
// isolation (no JSContext crash paths), and the CRLF guard on plugin output.
// All run against a fixture directory injected via SIPHON_PLUGINS_DIR.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("plugin-tests-\(UUID().uuidString)", isDirectory: true)
setenv("SIPHON_PLUGINS_DIR", dir.path, 1)

func makePlugin(_ name: String, manifest: String, script: String) {
    let p = dir.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    try? manifest.write(to: p.appendingPathComponent("manifest.json"),
                        atomically: true, encoding: .utf8)
    try? script.write(to: p.appendingPathComponent("main.js"),
                      atomically: true, encoding: .utf8)
}

// MARK: - glob matcher (pure)

check(PluginHost.patternMatches("example.com/*",
      url: URL(string: "https://example.com/file.bin")!), "glob: exact host + star path")
check(!PluginHost.patternMatches("example.com/*",
      url: URL(string: "https://evil.com/file.bin")!), "glob: wrong host rejected")
check(PluginHost.patternMatches("*.example.com/*",
      url: URL(string: "https://cdn.example.com/a.bin")!), "glob: subdomain wildcard")
check(!PluginHost.patternMatches("*.example.com/*",
      url: URL(string: "https://notexample.com/a.bin")!), "glob: suffix lookalike rejected")
check(PluginHost.patternMatches("example.com/v*/big.bin",
      url: URL(string: "https://example.com/v2/big.bin")!), "glob: mid-path wildcard")
check(!PluginHost.patternMatches("example.com/*",
      url: URL(string: "https://example.com/sub/deep.bin")!),
      "glob: * does not cross / (POSIX fnmatch semantics)")

// MARK: - working plugin

makePlugin("good", manifest: #"{"name":"GoodPlugin","version":"1.0","match":["mirror.test/*"]}"#,
           script: """
           function resolve(url, headers) {
             return { url: url.replace("mirror.test", "fast.test"),
                      headers: Object.assign({}, headers, { Referer: "https://mirror.test/" }),
                      name: "renamed-by-plugin.bin" };
           }
           """)
// Broken plugin: script throws → must be skipped, never crash the host.
makePlugin("broken", manifest: #"{"name":"Broken","match":["broken.test/*"]}"#,
           script: "function resolve(url, h) { throw new Error('boom'); }")
// Invalid manifest: no match patterns → skipped at load.
makePlugin("badmanifest", manifest: #"{"name":"NoMatch"}"#,
           script: "function resolve() { return null; }")

PluginHost.shared.reload()
// "good" and "broken" both load (broken's script compiles; it fails only at
// call time — tested below). "badmanifest" (no match patterns) must be skipped.
check(PluginHost.shared.count == 2, "manifest without match patterns is skipped",
      "got \(PluginHost.shared.count)")
check(PluginHost.shared.pluginNames.contains("GoodPlugin")
      && !PluginHost.shared.pluginNames.contains("NoMatch"),
      "plugin name from manifest; bad manifest excluded",
      "got \(PluginHost.shared.pluginNames)")

if let resolved = PluginHost.shared.resolve(urlString: "https://mirror.test/file.bin",
                                            headers: ["User-Agent": "Siphon/1.0"]) {
    check(resolved.url.absoluteString == "https://fast.test/file.bin",
          "plugin rewrote the URL", resolved.url.absoluteString)
    check(resolved.headers["Referer"] == "https://mirror.test/",
          "plugin-added header captured")
    check(resolved.headers["User-Agent"] == "Siphon/1.0",
          "original headers preserved through merge")
    check(resolved.name == "renamed-by-plugin.bin", "plugin-supplied name captured")
} else {
    check(false, "plugin resolved the URL")
}

// Non-matching URL → nil (falls through to normal pipeline).
check(PluginHost.shared.resolve(urlString: "https://unrelated.test/f.zip", headers: [:]) == nil,
      "non-matching URL returns nil")
// Not a URL at all → nil.
check(PluginHost.shared.resolve(urlString: "not a url", headers: [:]) == nil,
      "garbage input returns nil")

// MARK: - CRLF guard on plugin output

makePlugin("injector", manifest: #"{"name":"Injector","match":["inject.test/*"]}"#,
           script: """
           function resolve(url, headers) {
             return { url: "https://ok.test/a.bin",
                      headers: { Cookie: "a=1\\r\\nX-Evil: yes" },
                      name: "bad\\nname.bin" };
           }
           """)
PluginHost.shared.reload()
if let resolved = PluginHost.shared.resolve(urlString: "https://inject.test/x", headers: [:]) {
    check(resolved.headers["Cookie"] == "a=1 X-Evil: yes" || resolved.headers["Cookie"] == "a=1X-Evil: yes",
          "CRLF stripped from plugin headers", "got \(resolved.headers["Cookie"] ?? "nil")")
    check(!resolved.name!.contains("\n"), "control chars stripped from plugin name")
} else {
    check(false, "injector plugin resolved")
}

// MARK: - broken plugin: script throws → resolve returns nil, no crash

if let resolved = PluginHost.shared.resolve(urlString: "https://broken.test/x", headers: [:]) {
    check(false, "throwing plugin returns nil", "unexpectedly resolved: \(resolved)")
} else {
    check(true, "throwing plugin returns nil, host survives")
}

try? FileManager.default.removeItem(at: dir)

if failures == 0 { print("PLUGIN HOST TESTS PASSED") }
else { print("PLUGIN HOST TESTS FAILED: \(failures)"); exit(1) }

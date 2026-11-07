import Foundation

// Streaming preview server: Range handling, token/host guards, and the live
// watermark that lets a player read bytes appended after the request opened.

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("siphon-preview-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let file = tmp.appendingPathComponent("movie.mp4")
let firstHalf = Data((0..<4096).map { UInt8($0 % 251) })
try! firstHalf.write(to: file)
let secondHalf = Data((0..<4096).map { UInt8(($0 + 128) % 251) })

let registry = PreviewRegistry()
let token = "0123456789abcdef0123456789abcdef"
let port: UInt16 = 18768
let server = PreviewServer(port: port, token: token, registry: registry)
check(server.start(), "server starts on loopback:\(port)")
defer { server.stop() }

let taskID = UUID()
registry.register(taskID: taskID, fileURL: file, totalBytes: 8192, downloadedBytes: 4096)

func makeURL(token tokenValue: String) -> URL {
    var comps = URLComponents(string: "http://127.0.0.1:\(port)/preview/\(taskID.uuidString)")!
    comps.queryItems = [URLQueryItem(name: "token", value: tokenValue)]
    return comps.url!
}

/// Returns status, body and selected headers.
func request(_ url: URL, method: String = "GET", range: String? = nil,
             timeout: TimeInterval = 12) -> (status: Int, body: Data, headers: [String: String]) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    if let range { req.setValue(range, forHTTPHeaderField: "Range") }
    var status = 0
    var body = Data()
    var headers: [String: String] = [:]
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            for (k, v) in http.allHeaderFields {
                headers[String(describing: k).lowercased()] = String(describing: v)
            }
        }
        body = data ?? Data()
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return (status, body, headers)
}

// 1. Token and host guards.
let badToken = request(makeURL(token: "deadbeef"))
check(badToken.status == 403, "bad token → 403")

let unknown = request(URL(string: "http://127.0.0.1:\(port)/preview/\(UUID().uuidString)?token=\(token)")!)
check(unknown.status == 404, "unknown task → 404")

// 2. HEAD returns metadata without a body.
let head = request(makeURL(token: token), method: "HEAD", range: "bytes=0-4095")
check(head.status == 206, "HEAD range → 206")
check(head.body.isEmpty, "HEAD has no body")
check(head.headers["content-range"] == "bytes 0-4095/8192", "HEAD advertises Content-Range")
check(head.headers["accept-ranges"] == "bytes", "HEAD advertises Accept-Ranges")

// 3. Plain Range read of bytes already on disk.
let range1 = request(makeURL(token: token), range: "bytes=0-4095")
check(range1.status == 206, "Range 0-4095 → 206")
check(range1.body == firstHalf, "Range 0-4095 body matches disk")
check(range1.headers["content-type"] == "video/mp4", "mp4 gets video/mp4")

// 4. A read past the watermark blocks, then returns the appended bytes.
let laterDone = DispatchSemaphore(value: 0)
var laterStatus = 0
var laterBody = Data()
var laterRequest = URLRequest(url: makeURL(token: token))
laterRequest.setValue("bytes=4096-8191", forHTTPHeaderField: "Range")
laterRequest.timeoutInterval = 20
URLSession.shared.dataTask(with: laterRequest) { data, response, _ in
    laterStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
    laterBody = data ?? Data()
    laterDone.signal()
}.resume()

Thread.sleep(forTimeInterval: 0.25)
// Simulate the engine finishing the second half.
try! (firstHalf + secondHalf).write(to: file)
registry.update(taskID: taskID, downloaded: 8192, total: 8192)
check(laterDone.wait(timeout: .now() + 15) == .success, "blocked Range completes after append")
check(laterStatus == 206, "blocked Range → 206")
check(laterBody == secondHalf, "blocked Range returns newly written bytes")

// 5. Unsatisfiable range.
let beyond = request(makeURL(token: token), range: "bytes=9000-")
check(beyond.status == 416, "range beyond total → 416")
check(beyond.headers["content-range"] == "bytes */8192", "416 advertises total size")

// 6. Pure parser checks.
let full = PreviewServer.parseRange(nil, total: 100)
check(!full.invalid && full.start == 0 && full.end == 99, "no Range → whole file")
let suffix = PreviewServer.parseRange("bytes=-20", total: 100)
check(!suffix.invalid && suffix.start == 80 && suffix.end == 99, "suffix Range")
let openEnded = PreviewServer.parseRange("bytes=50-", total: 100)
check(!openEnded.invalid && openEnded.start == 50 && openEnded.end == 99, "open-ended Range")
let malformed = PreviewServer.parseRange("items=0-10", total: 100)
check(malformed.invalid, "non-bytes unit rejected")
let multi = PreviewServer.parseRange("bytes=0-10,20-30", total: 100)
check(multi.invalid, "multi-range rejected")

if failures > 0 {
    print("PREVIEW SERVER TESTS FAILED (\(failures))")
    exit(1)
}
print("PREVIEW SERVER TESTS PASSED")

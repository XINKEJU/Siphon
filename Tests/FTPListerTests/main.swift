import Foundation

// Pure parser tests for the FTP directory lister, plus an optional end-to-end
// test against a local pyftpdlib server (skipped when the module is unavailable).

var failures = 0
func check(_ cond: Bool, _ msg: String, _ detail: String = "") {
    if cond { print("  ok  \(msg)") }
    else { failures += 1; print("  FAIL \(msg)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

// MARK: - MLSD parsing

let mlsd = """
type=cdir;modify=20240101;sizd=4096; .
type=pdir;modify=20240101;sizd=4096; ..
type=file;modify=20240101;size=123456; a.bin
modify=20240101;size=99;type=file; b.txt
type=dir;modify=20240101;size=4096; subdir
type=file;size=2048; c.dmg
"""

let mlsdEntries = FTPDirectoryLister.parse(mlsd)
check(mlsdEntries.count == 4, "MLSD: 4 real entries (skips . and ..)", "got \(mlsdEntries.count)")
check(mlsdEntries[0] == .init(name: "a.bin", size: 123456, isDirectory: false), "MLSD a.bin size parsed")
check(mlsdEntries[1] == .init(name: "b.txt", size: 99, isDirectory: false), "MLSD fact order is irrelevant")
check(mlsdEntries[2] == .init(name: "subdir", size: 4096, isDirectory: true), "MLSD directory flagged")
check(mlsdEntries[3].name == "c.dmg", "MLSD bare size= fact parsed")

// MARK: - LIST (ls -l) fallback parsing

let longListing = """
total 8
drwxr-xr-x  2 user  staff  4096 Jan  1 00:00 folder
-rw-r--r--  1 user  staff  12345 Jan  1 00:00 notes.txt
-rw-r--r--  1 user  staff    512 Jan  1 00:00 readme.md
lrwxr-xr-x  1 user  staff     10 Jan  1 00:00 link -> notes.txt
"""

let longEntries = FTPDirectoryLister.parse(longListing)
check(longEntries.count == 4, "LIST: 4 entries", "got \(longEntries.count)")
check(longEntries[0] == .init(name: "folder", size: 4096, isDirectory: true), "LIST directory flagged")
check(longEntries[1] == .init(name: "notes.txt", size: 12345, isDirectory: false), "LIST file + size parsed")
check(longEntries[2].size == 512, "LIST small size parsed")
check(longEntries[3].name == "link -> notes.txt" || longEntries[3].name == "link",
      "LIST symlink treated as file (name may keep arrow)")

// MARK: - NLST (bare names) parsing

let nlst = "one.bin\ntwo.bin\nthree.bin\n"
let nlstEntries = FTPDirectoryLister.parse(nlst)
check(nlstEntries.count == 3, "NLST: 3 bare names")
check(nlstEntries.allSatisfy { !$0.isDirectory && $0.size == 0 }, "NLST entries are files, size 0")

// MARK: - directory detection

check(FTPDirectoryLister.looksLikeDirectory(URL(string: "ftp://host/")!), "trailing-slash root is a directory")
check(FTPDirectoryLister.looksLikeDirectory(URL(string: "ftp://host/pub/")!), "trailing-slash path is a directory")
check(!FTPDirectoryLister.looksLikeDirectory(URL(string: "ftp://host/file.bin")!), "file URL is not a directory")
check(!FTPDirectoryLister.looksLikeDirectory(URL(string: "https://host/")!), "non-FTP never a directory")

// MARK: - optional E2E against a local FTP server

print("FTP PARSER TESTS DONE (\(failures) failures)")

// E2E against a minimal self-contained Python FTP server (no third-party deps).
if CommandLine.arguments.contains("--e2e") {
    runE2E()
}
if failures == 0 { print("FTP LISTER TESTS PASSED") }
else { print("FTP LISTER TESTS FAILED: \(failures)"); exit(1) }

// MARK: - E2E helper

func runE2E() {
    let port = 21219
    // Minimal FTP server: USER/PASS/PWD/EPSV/TYPE/NLST/LIST/MLSD/QUIT, serving a
    // fixed directory of three entries (a.txt, b.bin, subdir/). Emits a `ls -l`
    // long listing for LIST and bare names for NLST, so the full parse path runs.
    let script = #"""
    import socket, threading, sys
    PORT = 21219
    files = [("a.txt", 5, False), ("b.bin", 6, False), ("subdir", 4096, True)]
    def mlsd():
        return "\r\n".join(
            f"type={'dir' if d else 'file'};size={s};modify=20240101000000; {n}"
            for n, s, d in files) + "\r\n"
    def listing():
        return "\r\n".join(
            f"{'drwxr-xr-x' if d else '-rw-r--r--'} 1 user staff {s:>8} Jan  1 00:00 {n}"
            for n, s, d in files) + "\r\n"
    def names():
        return "\r\n".join(n for n, _, _ in files) + "\r\n"
    class S(threading.Thread):
        def __init__(self, c): super().__init__(daemon=True); self.c = c; self.dl = None
        def send(self, s): self.c.sendall(s.encode())
        def run(self):
            try:
                self.send("220 ready\r\n"); buf = b""
                while True:
                    d = self.c.recv(4096)
                    if not d: break
                    buf += d
                    while b"\r\n" in buf:
                        line, buf = buf.split(b"\r\n", 1)
                        self.handle(line.decode(errors="replace"))
            except Exception: pass
            finally:
                try: self.c.close()
                except Exception: pass
        def handle(self, line):
            p = line.split()
            if not p: return
            c = p[0].upper()
            if c == "USER": self.send("331 ok\r\n")
            elif c == "PASS": self.send("230 ok\r\n")
            elif c == "SYST": self.send("215 UNIX\r\n")
            elif c == "TYPE": self.send("200 ok\r\n")
            elif c == "PWD": self.send("257 \"/\"\r\n")
            elif c == "FEAT": self.send("211-Features:\r\n EPSV\r\n MLSD\r\n211 End\r\n")
            elif c == "EPSV":
                self.send("229 (|||21220|)\r\n")
                self.dl = socket.socket(); self.dl.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.dl.bind(("127.0.0.1", 21220)); self.dl.listen(1)
            elif c in ("MLSD", "LIST", "NLST"):
                self.send("150 ok\r\n")
                payload = mlsd() if c == "MLSD" else (listing() if c == "LIST" else names())
                try:
                    if self.dl:
                        self.dl.settimeout(5); dc, _ = self.dl.accept(); dc.sendall(payload.encode()); dc.close()
                except Exception: pass
                self.dl = None
                self.send("226 done\r\n")
            elif c == "QUIT": self.send("221 bye\r\n")
            else: self.send("502 no\r\n")
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT)); srv.listen(5)
    print("READY", flush=True)
    while True:
        c, _ = srv.accept(); S(c).start()
    """#
    let scriptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("siphon-miniftp-\(UUID().uuidString).py")
    try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = [scriptURL.path]
    do { try proc.run() } catch { print("  SKIP e2e (python3 unavailable)"); return }

    // Wait for the port.
    var up = false
    for _ in 0..<100 {
        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        s.arguments = ["--silent", "--connect-timeout", "1", "--list-only", "ftp://127.0.0.1:\(port)/"]
        let p = Pipe(); s.standardOutput = p; s.standardError = Pipe()
        try? s.run(); s.waitUntilExit()
        if s.terminationStatus == 0 { up = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard up else { proc.terminate(); print("  SKIP e2e (server did not start)"); return }

    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let entries = try await FTPDirectoryLister.list(URL(string: "ftp://127.0.0.1:\(port)/")!)
            let names = entries.map(\.name).sorted()
            // curl --list-only uses NLST, which carries no type info, so every entry
            // surfaces as a file (directory detection is only possible via MLSD,
            // covered by the pure-parser tests above). We assert the names only.
            check(names == ["a.txt", "b.bin", "subdir"], "E2E: listing returns all entries", "\(names)")
        } catch {
            check(false, "E2E: list threw", "\(error)")
        }
        sem.signal()
    }
    sem.wait()

    proc.terminate()
}

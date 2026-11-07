import Foundation

/// ~/.netrc credentials (aria2 / curl `--netrc` model). One file, every host:
/// `machine example.com login alice password s3cret`, with `default` as the
/// catch-all entry. We never write the file — parsing only — and the engine
/// consults it only when the server actually demands authentication, so a
/// netrc-less install behaves exactly as before.
///
/// Grammar per netrc(5): whitespace-separated tokens, several per line allowed.
/// `machine <name>`, `default`, `login <u>`, `password <p>`, `account <a>` and
/// `port <n>` (both ignored here), and `macdef <name>` whose macro body extends
/// to the following blank line and is skipped. Later entries for the same
/// machine win (last match, like curl).
public enum NetRC {
    public struct Entry: Equatable, Sendable {
        public let machine: String   // host name, or "default"
        public let login: String
        public let password: String
    }

    static var filePath = NSString(string: "~/.netrc").expandingTildeInPath

    // MARK: - parsing (pure, unit-tested)

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var machine: String?
        var login: String?
        var password: String?
        var pendingKey: String?   // key whose value token comes next
        var inMacdef = false

        func flush() {
            if let m = machine, let l = login, let p = password {
                entries.append(Entry(machine: m, login: l, password: p))
            }
            machine = nil; login = nil; password = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.isEmpty {
                // A blank line terminates a macdef body (netrc(5)) and any
                // dangling key from a malformed line.
                inMacdef = false
                pendingKey = nil
                continue
            }
            if inMacdef { continue }
            for token in tokens {
                if let key = pendingKey {
                    switch key {
                    case "machine": machine = token
                    case "login": login = token
                    case "password": password = token
                    default: break // account/port: consume and ignore the value
                    }
                    pendingKey = nil
                    continue
                }
                switch token {
                case "machine":
                    flush()          // a new machine record starts a new entry
                    pendingKey = "machine"
                case "default":
                    flush()
                    machine = "default"
                case "login": pendingKey = "login"
                case "password": pendingKey = "password"
                case "account", "port": pendingKey = "ignore"
                case "macdef": inMacdef = true
                default: break       // stray token: skip
                }
            }
        }
        flush()
        return entries
    }

    public static func entries() -> [Entry] {
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    // MARK: - lookup (pure, unit-tested)

    /// Host lookup: exact machine match (case-insensitive, last entry wins),
    /// falling back to the `default` record. nil when the host has no entry.
    public static func credential(forHost host: String, entries: [Entry])
        -> (login: String, password: String)? {
        let h = host.lowercased()
        if let e = entries.last(where: { $0.machine.lowercased() == h }) {
            return (e.login, e.password)
        }
        if let d = entries.last(where: { $0.machine == "default" }) {
            return (d.login, d.password)
        }
        return nil
    }

    public static func credential(forHost host: String?) -> (login: String, password: String)? {
        guard let host, !host.isEmpty else { return nil }
        return credential(forHost: host, entries: entries())
    }
}

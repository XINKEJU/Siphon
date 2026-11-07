import Foundation

// Offline tests for NetRC parsing and host lookup (no filesystem, no network).
var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("FAIL: \(name)") }
}
func eq<T: Equatable>(_ a: T?, _ b: T?, _ name: String) {
    check(name, a == b)
}

// Standard single-line entry
var e = NetRC.parse("machine example.com login alice password s3cret\n")
check("single entry", e.count == 1 && e[0].machine == "example.com"
      && e[0].login == "alice" && e[0].password == "s3cret")

// Tokens split across lines (legal per netrc(5))
e = NetRC.parse("machine example.com\nlogin bob\n\npassword pw2\n")
check("tokens across lines", e.count == 1 && e[0].login == "bob" && e[0].password == "pw2")

// Multiple machines, later wins on duplicate
e = NetRC.parse("""
machine a.com login u1 password p1
machine b.com login u2 password p2
machine a.com login u3 password p3
""")
check("three entries", e.count == 3)
check("duplicate machine last wins", e.last?.login == "u3")

// default entry
e = NetRC.parse("machine a.com login u1 password p1\ndefault login anon password anonpw\n")
check("default parsed", e.count == 2 && e[1].machine == "default")
check("exact host beats default",
      NetRC.credential(forHost: "A.com", entries: e)?.login == "u1")
check("default used for unknown host",
      NetRC.credential(forHost: "other.org", entries: e)?.login == "anon")
check("unknown host no default",
      NetRC.credential(forHost: "x.org", entries: NetRC.parse(
        "machine a.com login u1 password p1")) == nil)

// account / port values are consumed, not treated as keywords
e = NetRC.parse("machine a.com account myacct port 443 login u9 password p9\n")
check("account+port consumed", e.count == 1 && e[0].login == "u9" && e[0].password == "p9")

// macdef body skipped entirely; ends at blank line
e = NetRC.parse("""
machine a.com login u1 password p1
macdef upload
login decoy password decoypw
put file.txt

machine b.com login u2 password p2
""")
check("macdef body skipped", e.count == 2)
check("no decoy entry", !e.contains { $0.login == "decoy" })
check("entry after macdef parsed", e.last?.machine == "b.com")

// Incomplete entry (no password) is dropped, doesn't corrupt the next one
e = NetRC.parse("machine a.com login onlylogin\nmachine b.com login u2 password p2\n")
check("incomplete entry dropped", e.count == 1 && e[0].machine == "b.com")

// Empty / garbage input
check("empty text", NetRC.parse("").isEmpty)
check("garbage text", NetRC.parse("hello world\n").isEmpty)

print("PASS: \(pass)  FAIL: \(fail)")
exit(fail == 0 ? 0 : 1)

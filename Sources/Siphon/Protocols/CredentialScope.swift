import Foundation

/// Scopes credential headers to the site they were issued for.
///
/// A download's headers are captured against one URL (the page, the playlist, the
/// manifest) but the bytes often come from somewhere else: HLS/DASH segments and
/// `EXT-X-KEY` keys are routinely served by a different CDN host, and any request
/// can be redirected. Replaying `Cookie` / `Authorization` verbatim against those
/// hosts hands the user's session to a third party.
///
/// Rules (browser-equivalent, FluxDown `credential_scope` model):
/// - `Authorization` / `Proxy-Authorization`: same **origin** only (scheme + host + port).
/// - `Cookie` / `Cookie2`: same **site** (registrable domain) only, and never across
///   an https → http downgrade.
/// - `Referer`: dropped on https → http downgrade, as browsers do.
/// - Everything else (User-Agent, Accept, hotlink-protection headers, …) passes
///   through untouched — those are needed for the download to succeed at all.
public enum CredentialScope {

    /// Header names that carry credentials. Compared lowercased.
    public static let originScopedNames: Set<String> = ["authorization", "proxy-authorization"]
    public static let siteScopedNames: Set<String> = ["cookie", "cookie2"]
    public static var sensitiveNames: Set<String> { originScopedNames.union(siteScopedNames) }

    // MARK: - site / origin comparison

    /// Registrable domain (eTLD+1) of a host, or the host itself for IP literals
    /// and single-label names.
    ///
    /// Uses a curated set of multi-label public suffixes rather than the full
    /// public-suffix list: unknown suffixes fall back to the last two labels,
    /// which is correct for every gTLD and flat ccTLD. The curated entries cover
    /// the registries that actually delegate second-level domains, so
    /// `evil.co.uk` and `bank.co.uk` are never treated as one site.
    public static func registrableDomain(of host: String) -> String {
        let h = normalizeHost(host)
        guard !h.isEmpty else { return "" }
        if isIPLiteral(h) || !h.contains(".") { return h }
        let labels = h.split(separator: ".")
        guard labels.count > 2 else { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    public static func siteKey(of url: URL) -> String {
        registrableDomain(of: url.host ?? "")
    }

    public static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        let ka = siteKey(of: a), kb = siteKey(of: b)
        return !ka.isEmpty && ka == kb
    }

    public static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard normalizeHost(a.host ?? "") == normalizeHost(b.host ?? ""),
              (a.scheme ?? "").lowercased() == (b.scheme ?? "").lowercased(),
              effectivePort(a) == effectivePort(b) else { return false }
        return !(a.host ?? "").isEmpty
    }

    // MARK: - header filtering

    /// The subset of `headers` that may be sent to `target` when they were
    /// captured for `origin`. Non-credential headers are always kept.
    public static func headers(_ headers: [String: String],
                               from origin: URL, to target: URL) -> [String: String] {
        let sameOrigin = isSameOrigin(origin, target)
        let sameSite = isSameSite(origin, target)
        let downgraded = (origin.scheme ?? "").lowercased() == "https"
            && (target.scheme ?? "").lowercased() == "http"
        var out: [String: String] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            if originScopedNames.contains(key) {
                if sameOrigin { out[name] = value }
                continue
            }
            if siteScopedNames.contains(key) {
                if sameSite && !downgraded { out[name] = value }
                continue
            }
            if key == "referer" && downgraded { continue }
            out[name] = value
        }
        return out
    }

    /// Drop credential headers from an about-to-be-followed redirect request when
    /// the hop crosses the boundary they were issued for. `from` is the URL that
    /// produced the 3xx, `to` the redirect target.
    public static func strippingDisallowedCredentials(in request: URLRequest,
                                                      from: URL, to: URL) -> URLRequest {
        guard let present = request.allHTTPHeaderFields, !present.isEmpty else { return request }
        let allowed = headers(present, from: from, to: to)
        var scoped = request
        var changed = false
        for name in present.keys where sensitiveNames.contains(name.lowercased())
            || name.lowercased() == "referer" {
            if allowed[name] == nil {
                scoped.setValue(nil, forHTTPHeaderField: name)
                changed = true
            }
        }
        return changed ? scoped : request
    }

    // MARK: - helpers

    static func normalizeHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func effectivePort(_ url: URL) -> Int? {
        if let p = url.port { return p }
        switch (url.scheme ?? "").lowercased() {
        case "http": return 80
        case "https": return 443
        case "ftp": return 21
        case "ftps": return 990
        default: return nil
        }
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }  // IPv6 (URL.host strips the brackets)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber)
                && (Int(part) ?? 256) <= 255
        }
    }

    /// Curated multi-label public suffixes (the `co.uk` / `com.cn` class).
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "ac.uk",
        "gov.uk", "mod.uk", "nhs.uk", "police.uk", "judiciary.uk",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "mil.cn",
        "com.hk", "edu.hk", "gov.hk", "idv.hk", "net.hk", "org.hk",
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw", "idv.tw", "mil.tw",
        "com.mo", "net.mo", "org.mo", "edu.mo", "gov.mo",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "ad.jp", "ed.jp", "go.jp", "gr.jp", "lg.jp",
        "co.kr", "or.kr", "ne.kr", "re.kr", "pe.kr", "go.kr", "mil.kr", "ac.kr",
        "hs.kr", "ms.kr", "es.kr", "sc.kr", "kg.kr",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz", "geek.nz", "gen.nz",
        "health.nz", "iwi.nz", "kiwi.nz", "maori.nz", "mil.nz", "school.nz",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "ecn.br",
        "emp.br", "esp.br", "etc.br", "eti.br", "far.br", "fnd.br", "fot.br",
        "fst.br", "g12.br", "ggf.br", "imb.br", "ind.br", "inf.br", "jor.br",
        "jus.br", "leg.br", "lel.br", "mat.br", "med.br", "mil.br", "mp.br",
        "mus.br", "nom.br", "not.br", "ntr.br", "odo.br", "ppg.br", "pro.br",
        "psc.br", "psi.br", "qsl.br", "radio.br", "rec.br", "slg.br", "srv.br",
        "taxi.br", "teo.br", "tmp.br", "trd.br", "tur.br", "tv.br", "vet.br",
        "zlg.br",
        "co.in", "net.in", "org.in", "gen.in", "ind.in", "firm.in", "ac.in",
        "edu.in", "res.in", "gov.in", "mil.in", "nic.in",
        "co.id", "or.id", "ac.id", "go.id", "mil.id", "net.id", "sch.id", "web.id",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg", "per.sg",
        "com.my", "net.my", "org.my", "edu.my", "gov.my", "mil.my", "name.my",
        "co.th", "or.th", "ac.th", "go.th", "mi.th", "net.th", "in.th",
        "com.ph", "net.ph", "org.ph", "edu.ph", "gov.ph", "mil.ph", "ngo.ph",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn", "int.vn", "ac.vn",
        "biz.vn", "info.vn", "name.vn", "pro.vn", "health.vn",
        "com.mx", "org.mx", "net.mx", "edu.mx", "gob.mx",
        "com.ar", "net.ar", "org.ar", "edu.ar", "gob.ar", "gov.ar", "int.ar",
        "mil.ar", "tur.ar",
        "com.co", "net.co", "org.co", "edu.co", "gov.co", "mil.co", "nom.co",
        "com.pe", "net.pe", "org.pe", "edu.pe", "gob.pe", "mil.pe", "nom.pe",
        "com.cl", "gob.cl", "gov.cl",
        "com.ec", "net.ec", "org.ec", "edu.ec", "gob.ec", "gov.ec", "fin.ec", "med.ec",
        "com.uy", "edu.uy", "gub.uy", "mil.uy", "net.uy", "org.uy",
        "com.ve", "net.ve", "org.ve", "edu.ve", "gov.ve", "mil.ve", "co.ve",
        "com.bo", "net.bo", "org.bo", "edu.bo", "gob.bo", "gov.bo", "mil.bo",
        "com.py", "net.py", "org.py", "edu.py", "gov.py", "mil.py",
        "com.gt", "net.gt", "org.gt", "edu.gt", "gob.gt", "mil.gt",
        "com.sv", "edu.sv", "gob.sv", "org.sv", "red.sv",
        "com.hn", "net.hn", "org.hn", "edu.hn", "gob.hn", "mil.hn",
        "com.ni", "net.ni", "org.ni", "edu.ni", "gob.ni", "mil.ni",
        "com.cr", "or.cr", "ac.cr", "co.cr", "ed.cr", "fi.cr", "go.cr", "sa.cr",
        "com.pa", "net.pa", "org.pa", "edu.pa", "gob.pa", "ac.pa",
        "com.do", "net.do", "org.do", "edu.do", "gob.do", "gov.do", "mil.do",
        "com.cu", "net.cu", "org.cu", "edu.cu", "gov.cu",
        "co.za", "org.za", "net.za", "ac.za", "gov.za", "edu.za", "mil.za",
        "alt.za", "ngo.za", "nom.za", "school.za", "tm.za", "web.za",
        "co.ke", "or.ke", "ne.ke", "go.ke", "ac.ke", "sc.ke", "me.ke", "mobi.ke", "info.ke",
        "com.ng", "edu.ng", "gov.ng", "net.ng", "org.ng", "sch.ng", "name.ng",
        "com.gh", "edu.gh", "gov.gh", "org.gh", "mil.gh",
        "co.tz", "or.tz", "ne.tz", "ac.tz", "go.tz", "hotel.tz", "info.tz", "me.tz",
        "co.ug", "or.ug", "ac.ug", "sc.ug", "go.ug", "ne.ug", "com.ug", "org.ug",
        "co.zw", "org.zw", "ac.zw", "gov.zw",
        "com.eg", "edu.eg", "gov.eg", "net.eg", "org.eg", "sci.eg", "mil.eg",
        "com.tr", "net.tr", "org.tr", "edu.tr", "gov.tr", "mil.tr", "bel.tr",
        "av.tr", "dr.tr", "k12.tr", "pol.tr", "tsk.tr",
        "co.il", "org.il", "net.il", "ac.il", "gov.il", "muni.il", "idf.il", "k12.il",
        "com.sa", "net.sa", "org.sa", "edu.sa", "gov.sa", "med.sa", "pub.sa", "sch.sa",
        "com.ae", "net.ae", "org.ae", "ac.ae", "gov.ae", "mil.ae", "sch.ae",
        "com.qa", "net.qa", "org.qa", "edu.qa", "gov.qa", "mil.qa",
        "com.kw", "net.kw", "org.kw", "edu.kw", "gov.kw",
        "com.bh", "net.bh", "org.bh", "edu.bh", "gov.bh",
        "com.om", "net.om", "org.om", "edu.om", "gov.om", "med.om",
        "com.jo", "net.jo", "org.jo", "edu.jo", "gov.jo", "mil.jo",
        "com.lb", "net.lb", "org.lb", "edu.lb", "gov.lb",
        "com.pk", "net.pk", "org.pk", "edu.pk", "gov.pk", "fam.pk", "biz.pk", "web.pk",
        "com.bd", "net.bd", "org.bd", "edu.bd", "gov.bd", "ac.bd", "mil.bd",
        "com.lk", "net.lk", "org.lk", "edu.lk", "gov.lk", "sch.lk", "ltd.lk",
        "com.np", "net.np", "org.np", "edu.np", "gov.np", "mil.np",
        "com.kh", "net.kh", "org.kh", "edu.kh", "gov.kh",
        "com.mm", "net.mm", "org.mm", "edu.mm", "gov.mm",
        "com.la", "net.la", "org.la", "edu.la", "gov.la",
        "com.bn", "net.bn", "org.bn", "edu.bn", "gov.bn",
        "co.ir", "ac.ir", "org.ir", "net.ir", "gov.ir", "sch.ir",
        "com.pl", "net.pl", "org.pl", "edu.pl", "gov.pl", "info.pl", "biz.pl",
        "waw.pl", "krakow.pl", "poznan.pl", "wroclaw.pl", "lodz.pl", "szczecin.pl",
        "gdansk.pl", "katowice.pl", "lublin.pl", "bialystok.pl", "rzeszow.pl",
        "com.ua", "net.ua", "org.ua", "edu.ua", "gov.ua", "in.ua", "kiev.ua",
        "co.at", "or.at", "ac.at", "gv.at", "priv.at",
        "com.de", "org.de", "net.de",
        "com.es", "org.es", "net.es", "edu.es", "gob.es", "nom.es",
        "com.pt", "org.pt", "net.pt", "edu.pt", "gov.pt", "nome.pt", "publ.pt",
        "com.gr", "net.gr", "org.gr", "edu.gr", "gov.gr",
        "com.it", "org.it", "net.it", "edu.it", "gov.it",
        "co.hu", "org.hu", "net.hu", "edu.hu", "gov.hu",
        "com.ro", "org.ro", "net.ro", "edu.ro", "gov.ro", "nom.ro", "nt.ro",
        "com.ru", "net.ru", "org.ru", "msk.ru", "spb.ru", "pp.ru",
        "com.by", "net.by", "org.by", "edu.by", "gov.by", "mil.by",
        "com.kz", "net.kz", "org.kz", "edu.kz", "gov.kz", "mil.kz",
        "com.uz", "net.uz", "org.uz", "edu.uz", "gov.uz",
        "com.ge", "net.ge", "org.ge", "edu.ge", "gov.ge",
        "com.am", "net.am", "org.am", "edu.am", "gov.am",
        "com.az", "net.az", "org.az", "edu.az", "gov.az", "mil.az",
        "com.cy", "net.cy", "org.cy", "ac.cy", "gov.cy", "ltd.cy",
        "com.mt", "net.mt", "org.mt", "edu.mt", "gov.mt",
        "com.hr", "net.hr", "org.hr", "edu.hr", "gov.hr",
        "com.si", "net.si", "org.si", "edu.si", "gov.si",
        "com.mk", "net.mk", "org.mk", "edu.mk", "gov.mk",
        "com.al", "net.al", "org.al", "edu.al", "gov.al",
        "com.ba", "net.ba", "org.ba", "edu.ba", "gov.ba",
        "com.ee", "net.ee", "org.ee", "edu.ee", "gov.ee",
        "com.lv", "net.lv", "org.lv", "edu.lv", "gov.lv",
        "com.lt", "net.lt", "org.lt", "edu.lt", "gov.lt",
        "com.md", "net.md", "org.md", "edu.md", "gov.md",
        "com.fi", "net.fi", "org.fi", "edu.fi", "gov.fi",
        "com.no", "net.no", "org.no", "edu.no", "gov.no",
        "com.se", "net.se", "org.se", "edu.se", "gov.se",
        "com.dk", "net.dk", "org.dk", "edu.dk", "gov.dk",
        "co.nl", "net.nl", "org.nl",
        "com.be", "net.be", "org.be", "ac.be", "gov.be",
        "com.lu", "net.lu", "org.lu", "edu.lu", "gov.lu",
        "com.fr", "net.fr", "org.fr", "edu.fr", "gouv.fr",
        "com.re", "net.re", "org.re",
        "com.ch", "net.ch", "org.ch",
        "com.ca", "net.ca", "org.ca", "edu.ca", "gov.ca", "qc.ca", "ab.ca",
        "bc.ca", "on.ca", "mb.ca", "sk.ca", "ns.ca", "nb.ca", "nl.ca", "pe.ca",
        "com.us", "net.us", "org.us", "edu.us", "gov.us", "mil.us",
        "k12.ca.us", "cc.ca.us", "lib.ca.us",
        "com.af", "net.af", "org.af", "edu.af", "gov.af",
    ]
}

// MARK: - redirect guard

/// Re-scopes credentials on every redirect hop. URLSession's default behaviour
/// copies all custom headers to the redirect target, which leaks a session cookie
/// or bearer token to whatever host the server names next.
final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Entitlement is judged against the URL the headers were submitted for,
        // not against whichever intermediate hop produced this 3xx.
        let original = task.originalRequest
        guard let origin = original?.url, let to = request.url else {
            completionHandler(request)
            return
        }
        var scoped = CredentialScope.strippingDisallowedCredentials(in: request,
                                                                   from: origin, to: to)
        // URLSession drops Authorization on *every* redirect, same-origin included,
        // so an authenticated endpoint that 302s to a signed path on its own host
        // would 401. Put it back only when the target is still the issuing origin.
        if CredentialScope.isSameOrigin(origin, to), let issued = original?.allHTTPHeaderFields {
            for (name, value) in issued
            where CredentialScope.originScopedNames.contains(name.lowercased())
                && scoped.value(forHTTPHeaderField: name) == nil {
                scoped.setValue(value, forHTTPHeaderField: name)
            }
        }
        completionHandler(scoped)
    }

    /// Server demands authentication and the URL carried no userinfo:
    /// fall back to ~/.netrc (aria2/curl model). Fires once per task — a
    /// repeated challenge means the netrc password is wrong, so we let it fail
    /// instead of looping against the same bad credential.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        let authMethods = [NSURLAuthenticationMethodHTTPBasic,
                           NSURLAuthenticationMethodHTTPDigest,
                           NSURLAuthenticationMethodNTLM]
        guard challenge.previousFailureCount == 0,
              authMethods.contains(method),
              let cred = NetRC.credential(forHost: challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential,
                          URLCredential(user: cred.login, password: cred.password,
                                        persistence: .forSession))
    }
}

extension CredentialScope {
    /// Session for playlist / manifest / key / segment fetches. Ephemeral so the
    /// shared `HTTPCookieStorage` can never inject cookies the caller did not
    /// explicitly supply, and every redirect hop is re-scoped.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c, delegate: CredentialRedirectGuard(), delegateQueue: nil)
    }()

    /// Build a download session with the redirect guard attached.
    public static func makeSession(_ configure: (URLSessionConfiguration) -> Void) -> URLSession {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        configure(c)
        return URLSession(configuration: c, delegate: CredentialRedirectGuard(), delegateQueue: nil)
    }
}
// Manifest V3 service worker for the Siphon connector (v3).
//
// NDM-style download interception:
//   - Monitors ALL browser downloads and redirects them to Siphon
//   - Detects downloadable content via Content-Type headers
//   - Matches file extensions for direct-link downloads
//   - Size-based filtering (configurable minimum threshold)
//   - Exclusion list for sites/file types that should use the browser
//   - Media sniffing for embedded video/audio streams
//
// Two transport paths to the app:
//   1. Native Messaging via the SiphonNM gateway (preferred — the token is
//      read by the gateway from a 0600 local file, no user setup needed)
//   2. Loopback HTTP fallback (http://127.0.0.1:17801/add), which needs the
//      token pasted once into the popup's 设置 tab. `/ping` is liveness only.

const ENDPOINT = "http://127.0.0.1:17801/add";
const BROWSER_ADD = "http://127.0.0.1:17801/browser/add";
const PING = "http://127.0.0.1:17801/ping";
const NATIVE_HOST = "com.xinkeju.siphon";
const APP_VERSION = chrome.runtime.getManifest().version;

const t = (key, fallback) => (chrome.i18n && chrome.i18n.getMessage(key)) || fallback;

// Fill `{name}` tokens in a translated string after chrome.i18n lookup.
const tf = (key, fallback, vars) => {
  let text = t(key, fallback);
  for (const [name, value] of Object.entries(vars || {})) {
    text = text.split(`{${name}}`).join(String(value));
  }
  return text;
};

// MARK: - file type patterns

const DOWNLOAD_EXTS = new Set([
  "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "tbz2", "lz", "lzma",
  "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
  "rtf", "epub", "mobi", "azw", "azw3", "djvu",
  "exe", "msi", "dmg", "pkg", "deb", "rpm", "apk", "ipa", "appimage",
  "iso", "img", "vmdk", "vdi", "vhd",
  "torrent",
]);

const MEDIA_EXTS = new Set([
  "mp4", "m4v", "webm", "mkv", "avi", "mov", "flv", "wmv", "mpg", "mpeg",
  "3gp", "3g2", "ts", "m2ts", "vob", "ogv",
  "mp3", "m4a", "aac", "flac", "ogg", "wav", "wma", "opus", "aiff", "ape",
  "m3u8", "mpd", "m3u",
]);

const DOWNLOAD_CTYPES = new Set([
  "application/octet-stream",
  "application/zip", "application/x-zip-compressed",
  "application/x-rar-compressed",
  "application/x-7z-compressed",
  "application/x-tar", "application/x-gtar",
  "application/gzip", "application/x-gzip",
  "application/x-bzip2", "application/x-xz",
  "application/pdf",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/x-executable", "application/x-dmg",
  "application/x-apple-diskimage",
  "application/vnd.android.package-archive",
  "application/x-debian-package", "application/x-redhat-package-manager",
  "application/x-iso9660-image",
  "application/x-bittorrent",
  "application/epub+zip", "application/x-mobipocket-ebook",
  "video/mp4", "video/webm", "video/x-matroska", "video/avi",
  "video/quicktime", "video/x-flv", "video/x-ms-wmv", "video/mpeg",
  "video/ogg", "video/3gpp", "video/3gpp2",
  "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac",
  "audio/ogg", "audio/wav", "audio/webm", "audio/x-wav",
  "application/x-mpegURL", "application/dash+xml",
]);

const SKIP_CTYPES = new Set([
  "text/html", "application/xhtml+xml",
  "text/xml", "application/xml",
  "application/json",
  "text/plain", "text/css", "text/javascript",
  "application/javascript", "application/x-javascript",
  "image/svg+xml",
  "font/woff", "font/woff2", "font/ttf", "font/otf",
]);

// Types a browser normally opens itself instead of saving. Only consulted when
// the app's rules say "don't take files the browser would open".
const OPENED_EXTS = new Set([
  "pdf", "epub", "mp3", "m4a", "aac", "wav", "ogg", "flac", "opus",
  "mp4", "m4v", "webm", "mov", "ogv",
]);

const BAD_URL_RE = /^(chrome|chrome-extension|edge|about|data|blob|javascript|moz-extension):/i;
const MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|webm|mkv|ts|avi|mov|mp3|m4a|aac|flac|ogg|wav|flv)(\?|#|$)/i;

const HOP_BY_HOP = new Set([
  "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding",
  "upgrade", "te", "trailer", "content-length", "content-encoding", "vary",
  "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest",
  "sec-fetch-user", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
  "if-modified-since", "if-none-match", "range", "accept-encoding",
  "accept-language", "accept", "cache-control", "pragma",
]);

function sanitizeHeaders(raw) {
  const out = {};
  for (const h of raw ?? []) {
    const name = (h.name || "").toLowerCase().trim();
    const value = (h.value || "").trim();
    if (!name || !value) continue;
    if (HOP_BY_HOP.has(name) || name.startsWith("sec-") || name.startsWith("proxy-")) continue;
    if (/[\r\n]/.test(value)) continue;
    out[h.name] = value;
  }
  return out;
}

function hasHeader(headers, name) {
  return Object.keys(headers).some(k => k.toLowerCase() === name.toLowerCase());
}

// MARK: - configuration

const DEFAULTS = {
  captureAll: true,
  minFileSize: 0,
  excludeHosts: [],
  excludeExts: [],
  notifyOnCapture: true,
  interceptMedia: true,
  interceptDocuments: true,
  interceptArchives: true,
  interceptInstallers: true,
};

// Older builds defaulted the size filter to 1 MiB and could persist
// `captureAll: false` from a popup that read an uninitialised config. That
// combination silently lets every browser download through, so repair the
// capture defaults exactly once on upgrade. Explicit user changes made after
// the migration are preserved.
const CAPTURE_MIGRATION_KEY = "captureDefaultsV2";

async function getConfig() {
  const stored = await chrome.storage.local.get(
    [...Object.keys(DEFAULTS), CAPTURE_MIGRATION_KEY]);
  const config = { ...DEFAULTS };
  for (const [k, v] of Object.entries(stored)) {
    if (k === CAPTURE_MIGRATION_KEY) continue;
    if (v !== undefined) config[k] = v;
  }
  if (!stored[CAPTURE_MIGRATION_KEY]) {
    const repaired = {
      captureAll: true,
      minFileSize: 0,
      notifyOnCapture: true,
      [CAPTURE_MIGRATION_KEY]: true,
    };
    await chrome.storage.local.set(repaired);
    config.captureAll = repaired.captureAll;
    config.minFileSize = repaired.minFileSize;
    config.notifyOnCapture = repaired.notifyOnCapture;
  }
  return config;
}

// MARK: - statistics

let stats = { intercepted: 0, skipped: 0, media: 0, errors: 0 };

async function loadStats() {
  const stored = await chrome.storage.session.get("stats");
  if (stored.stats) stats = { ...stats, ...stored.stats };
}

async function saveStats() {
  try { await chrome.storage.session.set({ stats }); } catch (_) {}
}

function bumpStat(key) {
  stats[key] = (stats[key] || 0) + 1;
  saveStats();
}

// MARK: - native messaging

// A missing / mismatched native host fails immediately. Retrying it on every
// download adds a 4 s delay before the HTTP fallback, by which time Chrome has
// already finished the download and `chrome.downloads.cancel` can no longer
// undo it. Back off briefly instead.
let nativeBlockedUntil = 0;

function sendNative(payload, timeoutMs = 4000) {
  if (Date.now() < nativeBlockedUntil) {
    return Promise.resolve({ ok: false, nativeError: t("bg_errNativeBackoff", "原生网关暂不可用（已退避）") });
  }
  return new Promise(resolve => {
    let done = false;
    let port;
    try {
      port = chrome.runtime.connectNative(NATIVE_HOST);
    } catch (e) {
      nativeBlockedUntil = Date.now() + 30_000;
      resolve({ ok: false, nativeError: String(e) });
      return;
    }
    const timer = setTimeout(() => {
      nativeBlockedUntil = Date.now() + 30_000;
      finish({ ok: false, nativeError: t("bg_errNativeTimeout", "原生网关响应超时") });
    }, timeoutMs);
    function finish(value) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { port.disconnect(); } catch (_) {}
      resolve(value || { ok: false });
    }
    port.onMessage.addListener(msg => {
      // A working host clears an earlier backoff: the next download should not
      // be held back by a host that has since been reinstalled.
      if (msg && msg.ok) nativeBlockedUntil = 0;
      finish(msg);
    });
    port.onDisconnect.addListener(() => {
      // Our own `port.disconnect()` after a successful reply also fires this;
      // only treat an unexpected disconnect as a broken host.
      if (done) return;
      const reason = chrome.runtime.lastError?.message
        || t("bg_errNativeMissing", "原生网关未安装或扩展 ID 不在白名单");
      void chrome.runtime.lastError;
      nativeBlockedUntil = Date.now() + 30_000;
      finish({ ok: false, nativeError: reason });
    });
    try {
      port.postMessage(payload);
    } catch (e) {
      nativeBlockedUntil = Date.now() + 30_000;
      finish({ ok: false, nativeError: String(e) });
    }
  });
}

// MARK: - hello / rules handshake
//
// MDM's extension announces itself with `hello` at install and at every browser
// start; the app answers the same capture rules it would for `rules`, and notes
// the browser + extension version so its Settings can show what really connects.
let rules = null;

async function refreshRules() {
  let reply;
  try {
    // The app may be closed; its gateway launches it and can take a few seconds.
    reply = await sendNative({
      hello: true,
      v: APP_VERSION,
      userAgent: navigator.userAgent,
      brands: ((navigator.userAgentData && navigator.userAgentData.brands) || [])
        .map(b => b.brand),
    }, 15000);
  } catch (_) {
    return null;
  }
  if (reply && reply.ok) {
    rules = reply;
    try { await chrome.storage.local.set({ rules }); } catch (_) {}
  }
  return reply;
}

async function loadRules() {
  if (rules) return rules;
  try { rules = (await chrome.storage.local.get("rules")).rules || null; } catch (_) {}
  return rules;
}

// MARK: - HTTP fallback token

let apiToken = null;
// The app no longer discloses the token over HTTP: `/ping` is unauthenticated,
// so anything readable from it would be readable by any local process. The
// gateway path obtains the token out of band; for this HTTP-only fallback the
// user copies it once from Siphon → 设置 → 集成 into the popup.
async function getToken() {
  if (apiToken) return apiToken;
  const stored = await chrome.storage.local.get("apiToken");
  apiToken = stored.apiToken || null;
  return apiToken;
}

async function sendHTTP(payload, endpoint = ENDPOINT) {
  try {
    const token = await getToken();
    const r = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(payload),
    });
    if (r.status === 401) {
      // There is no silent re-bootstrap any more: the token only changes when
      // the user rotates it in the app, so tell them to paste the new one.
      return {
        ok: false, via: "http", status: 401,
        error: token ? t("bg_errTokenRotated", "令牌无效或已轮换，请在 Siphon 设置 → 集成 复制后重新粘贴")
                     : t("bg_errTokenMissing", "缺少令牌，请在扩展「设置」中粘贴 Siphon 的本地接口令牌"),
      };
    }
    return { ok: r.ok, via: "http", status: r.status };
  } catch (e) {
    console.warn("[Siphon] app not reachable", e);
    return { ok: false };
  }
}

// MARK: - hand-off context (cookies, proxy, private window)

// Cookies and proxy settings are read once per host / few seconds; a "download
// all links" page can hand over hundreds of URLs and must not make hundreds of
// settings calls.
const cookieCache = new Map();
const COOKIE_TTL = 20_000;

function userAgentBrands() {
  try {
    return ((navigator.userAgentData && navigator.userAgentData.brands) || [])
      .map(b => b.brand);
  } catch (_) {
    return [];
  }
}

async function cookieJarFor(url) {
  let host = "";
  try { host = new URL(url).host; } catch (_) { return []; }
  const cached = cookieCache.get(host);
  if (cached && Date.now() - cached.at < COOKIE_TTL) return cached.jar;
  try {
    const cookies = await chrome.cookies.getAll({ url });
    const jar = (cookies || []).map(c => ({
      name: c.name, value: c.value, domain: c.domain, path: c.path,
      secure: c.secure, httpOnly: c.httpOnly,
      expirationDate: c.expirationDate, sameSite: c.sameSite,
    }));
    cookieCache.set(host, { at: Date.now(), jar });
    if (cookieCache.size > 100) cookieCache.clear();
    return jar;
  } catch (_) {
    return [];
  }
}

let proxyCache = null;

/// The browser's proxy for this window, in the shape the app understands.
/// `system` (or no proxy API) means "nothing sent": the app keeps its own
/// Options proxy, exactly as MDM does.
async function proxyContext(isPrivate) {
  if (!chrome.proxy || !chrome.proxy.settings) return {};
  if (proxyCache && Date.now() - proxyCache.at < 10_000) return proxyCache.value;
  try {
    const details = await chrome.proxy.settings.get({ incognito: !!isPrivate });
    const value = (details && details.value) || {};
    let out = {};
    if (value.mode === "pac_script" && value.pacScript && value.pacScript.data) {
      out.proxyPac = value.pacScript.data;
    } else if (value.mode === "fixed_servers" && value.rules) {
      const r = value.rules;
      const pick = r.singleProxy || r.proxyForHttps || r.proxyForHttp;
      if (pick && pick.host) {
        out.proxy = `${pick.scheme || "http"}://${pick.host}:${pick.port || 80}`;
      }
    }
    proxyCache = { at: Date.now(), value: out };
    return out;
  } catch (_) {
    return {};
  }
}

// MARK: - Alt/Option "keep in browser" pass
//
// A content script records the click's URL with a modifier; the next matching
// download is left alone. Kept in session storage so a service-worker restart
// between the click and onCreated does not lose it.
const PASS_KEY = "browserPasses";

async function markBrowserPass(url) {
  if (!url) return;
  try {
    const stored = await chrome.storage.session.get(PASS_KEY);
    const passes = stored[PASS_KEY] || {};
    passes[url] = Date.now() + 15_000;
    await chrome.storage.session.set({ [PASS_KEY]: passes });
  } catch (_) {}
}

async function consumeBrowserPass(url) {
  if (!url) return false;
  try {
    const stored = await chrome.storage.session.get(PASS_KEY);
    const passes = stored[PASS_KEY] || {};
    if (!(url in passes)) return false;
    const until = passes[url];
    delete passes[url];
    await chrome.storage.session.set({ [PASS_KEY]: passes });
    return Date.now() <= until;
  } catch (_) {
    return false;
  }
}

// MARK: - sending

/// MDM's flat hand-off. Every field the browser knows travels unchanged; the
/// app decides which ones it can use. `linksPart` marks a bulk page grab.
async function handoff(options) {
  const url = options.url;
  if (!url || BAD_URL_RE.test(url)) return { ok: false, error: t("bg_errUnsupported", "不支持的地址") };
  const jar = options.cookieJar || await cookieJarFor(url);
  const cookies = jar.map(c => `${c.name}=${c.value}`).join("; ");
  const payload = {
    v: APP_VERSION,
    userAgent: navigator.userAgent,
    brands: userAgentBrands(),
    url,
    referrer: options.referrer || "",
    pageUrl: options.pageUrl || options.referrer || "",
    filename: options.filename || "",
    nameGuessed: options.nameGuessed !== false,
    size: Math.max(0, Number(options.size || 0)),
    mime: options.mime || "",
    private: !!options.private,
    explicit: !!options.explicit,
    finalUrl: options.finalUrl || "",
    post: options.post || "",
    postType: options.postType || "",
  };
  if (jar.length) {
    payload.cookieJar = jar;
    payload.cookies = cookies;
  }
  if (options.linksPart) payload.linksPart = options.linksPart;
  Object.assign(payload, await proxyContext(payload.private));
  if (!payload.size) delete payload.size;
  if (!payload.mime) delete payload.mime;
  if (!payload.finalUrl) delete payload.finalUrl;
  if (!payload.post) { delete payload.post; delete payload.postType; }
  if (!payload.filename) delete payload.filename;

  // The gateway may start the app, which is why this timeout is long.
  const viaNative = await sendNative(payload, 20_000);
  if (viaNative && viaNative.ok) return { ok: true, via: "native" };
  // A definitive refusal from a reachable app must not be retried over HTTP.
  // "not-running" still may: the gateway might be the broken half while the
  // app keeps its loopback API up for the token-paste fallback.
  if (viaNative && !viaNative.nativeError && viaNative.ok === false
      && viaNative.why !== "not-running") {
    return { ok: false, via: "native", error: viaNative.error, why: viaNative.why };
  }
  const viaHTTP = await sendHTTP(payload, BROWSER_ADD);
  if (viaHTTP.ok) return viaHTTP;
  return {
    ...viaHTTP,
    nativeError: viaNative?.nativeError || "",
    error: viaHTTP.error || viaNative?.error || "",
  };
}

async function send(url, { referrer = "", referer = "", filename = "",
                           explicit = false, private: isPrivate = false } = {}) {
  return handoff({
    url,
    referrer: referrer || referer,
    filename,
    nameGuessed: !filename,
    explicit,
    private: isPrivate,
  });
}

/// "Download all links": deduplicated, throttled four at a time, and marked
/// with an MDM-style `linksPart` so the app can group the batch.
async function sendBatch(urls, { referrer = "", private: isPrivate = false,
                                 explicit = false, limit = 500 } = {}) {
  const list = [...new Set((urls || []).map(u => String(u || "").trim()))]
    .filter(u => /^https?:/i.test(u) && !BAD_URL_RE.test(u))
    .slice(0, limit);
  if (!list.length) return { ok: false, sent: 0, count: 0, error: t("bg_errNoLinks", "没有可下载的链接") };
  const batch = "b" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  let sent = 0;
  for (let i = 0; i < list.length; i += 4) {
    const part = list.slice(i, i + 4);
    const results = await Promise.all(part.map((url, j) => handoff({
      url,
      referrer,
      pageUrl: referrer,
      nameGuessed: true,
      private: isPrivate,
      explicit,
      linksPart: { batch, index: i + j, count: list.length },
    })));
    sent += results.filter(r => r.ok).length;
  }
  return { ok: sent > 0, sent, count: list.length };
}

// MARK: - URL analysis helpers

function getExt(url) {
  try {
    const pathname = new URL(url).pathname;
    const last = pathname.split("/").filter(Boolean).pop() || "";
    const dot = last.lastIndexOf(".");
    if (dot < 0 || dot === last.length - 1) return "";
    return last.slice(dot + 1).toLowerCase();
  } catch (_) {
    return "";
  }
}

function getHost(url) {
  try { return new URL(url).host; } catch (_) { return ""; }
}

function getFilename(url) {
  try {
    const pathname = new URL(url).pathname;
    const last = pathname.split("/").filter(Boolean).pop() || "";
    return decodeURIComponent(last) || "";
  } catch (_) {
    return "";
  }
}

/// The name the server actually gave the file (`Content-Disposition`). When
/// present the app must not replace it with the address's last segment.
function contentDispositionFilename(disposition) {
  if (!disposition) return "";
  const star = /filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i.exec(disposition);
  if (star) {
    try {
      return decodeURIComponent(star[1].trim().replace(/^"|"$/g, ""));
    } catch (_) { /* fall through */ }
  }
  const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(disposition);
  return plain ? plain[1].trim() : "";
}

function browserWouldOpen(ext, mime) {
  if (ext && OPENED_EXTS.has(ext)) return true;
  return /^(application\/pdf|audio\/|video\/)/i.test(mime || "");
}

function isExcluded(url, config) {
  const host = getHost(url);
  for (const pattern of config.excludeHosts || []) {
    if (host === pattern || host.endsWith("." + pattern)) return true;
    try {
      if (new RegExp(pattern).test(host)) return true;
    } catch (_) {}
  }
  const ext = getExt(url);
  if (ext && (config.excludeExts || []).includes(ext)) return true;
  return false;
}

function isDownloadableExt(url) {
  const ext = getExt(url);
  return ext && (DOWNLOAD_EXTS.has(ext) || MEDIA_EXTS.has(ext));
}

function isDownloadableCType(ctype) {
  if (!ctype) return false;
  const base = ctype.split(";")[0].trim().toLowerCase();
  return DOWNLOAD_CTYPES.has(base);
}

function isSkippableCType(ctype) {
  if (!ctype) return false;
  const base = ctype.split(";")[0].trim().toLowerCase();
  return SKIP_CTYPES.has(base) || base.startsWith("image/") || base.startsWith("text/") || base.startsWith("font/");
}

// MARK: - Content-Type tracking via webRequest

const responseInfo = new Map();
const RESPONSE_INFO_TTL = 30_000;

function trackResponse(url, info) {
  responseInfo.set(url, { ...info, at: Date.now() });
  if (responseInfo.size > 200) {
    const cutoff = Date.now() - RESPONSE_INFO_TTL;
    for (const [k, v] of responseInfo) {
      if (v.at < cutoff) responseInfo.delete(k);
    }
  }
}

function getTrackedResponse(url) {
  const info = responseInfo.get(url);
  if (!info) return null;
  if (Date.now() - info.at > RESPONSE_INFO_TTL) {
    responseInfo.delete(url);
    return null;
  }
  return info;
}

const TRACKED_TYPES = new Set(["main_frame", "sub_frame", "xmlhttprequest", "other", "media"]);

function onResponseHeaders(details) {
  // Downloads are usually `other` or `xmlhttprequest`, not main_frame — only
  // tracking frames meant Content-Disposition was never recorded.
  if (details.tabId < 0 || !TRACKED_TYPES.has(details.type)) return;
  const headers = details.responseHeaders || [];
  let ctype = "", clen = -1, cdisp = "";
  for (const h of headers) {
    const n = (h.name || "").toLowerCase();
    if (n === "content-type") ctype = h.value || "";
    else if (n === "content-length") clen = parseInt(h.value, 10) || -1;
    else if (n === "content-disposition") cdisp = h.value || "";
  }
  if (ctype || cdisp) {
    trackResponse(details.url, { ctype, clen, cdisp, tabId: details.tabId });
  }
}

const RESPONSE_FILTER = { urls: ["http://*/*", "https://*/*"] };
try {
  // MV3 needs extraHeaders to expose Content-Disposition on Chromium.
  chrome.webRequest.onHeadersReceived.addListener(
    onResponseHeaders, RESPONSE_FILTER, ["responseHeaders", "extraHeaders"]);
} catch (_) {
  // Firefox's webRequest does not accept extraHeaders.
  chrome.webRequest.onHeadersReceived.addListener(
    onResponseHeaders, RESPONSE_FILTER, ["responseHeaders"]);
}

// MARK: - form POST tracking
//
// A button that answers with a file looks like any other download; the form
// body only exists in the original request, so remember it briefly and replay
// it in the hand-off (MDM's PostData).
const postBodies = new Map();
const POST_TTL = 30_000;

function trackPostBody(url, body) {
  postBodies.set(url, { ...body, at: Date.now() });
  if (postBodies.size > 200) {
    const cutoff = Date.now() - POST_TTL;
    for (const [k, v] of postBodies) if (v.at < cutoff) postBodies.delete(k);
  }
}

function trackedPost(url) {
  const entry = postBodies.get(url);
  if (!entry) return null;
  if (Date.now() - entry.at > POST_TTL) {
    postBodies.delete(url);
    return null;
  }
  return entry;
}

try {
  chrome.webRequest.onBeforeRequest.addListener(details => {
    if (details.method !== "POST" || details.tabId < 0) return;
    const form = details.requestBody && details.requestBody.formData;
    if (!form) return;
    try {
      const body = new URLSearchParams();
      for (const [key, values] of Object.entries(form)) {
        for (const value of (values || [])) body.append(key, value);
      }
      trackPostBody(details.url, {
        post: body.toString(),
        postType: "application/x-www-form-urlencoded",
      });
    } catch (_) {}
  }, { urls: ["http://*/*", "https://*/*"] }, ["requestBody"]);
} catch (_) {
  // Firefox builds without requestBody still work; the POST is simply not replayed.
}

// MARK: - media sniffing

const sniffQueues = new Map();

function sniffKey(tabId) { return `sniff:${tabId}`; }

function addSniff(tabId, url, type = "media") {
  const prev = sniffQueues.get(tabId) || Promise.resolve();
  const next = prev.then(() => doAddSniff(tabId, url, type)).catch(() => {});
  sniffQueues.set(tabId, next);
  return next;
}

async function doAddSniff(tabId, url, type = "media") {
  const key = sniffKey(tabId);
  const stored = await chrome.storage.session.get(key);
  let list = stored[key] || [];
  const isSegment = /\.ts(\?|#|$)/i.test(url);
  if (isSegment && list.some(item => /\.m3u8(\?|#|$)/i.test(item.url))) return;
  list = list.filter(item => item.url !== url);
  list.unshift({ url, type, at: Date.now() });
  list = list.slice(0, 100);
  await chrome.storage.session.set({ [key]: list });
  updateBadge(tabId, list.length);
  if (type === "media") bumpStat("media");
}

async function updateBadge(tabId, count) {
  try {
    await chrome.action.setBadgeBackgroundColor({ tabId, color: "#0071e3" });
    await chrome.action.setBadgeText({ tabId, text: count > 0 ? String(count) : "" });
  } catch (_) {}
}

async function clearSniff(tabId) {
  try { await chrome.storage.session.remove(sniffKey(tabId)); } catch (_) {}
  updateBadge(tabId, 0);
}

async function listSniff(tabId) {
  if (tabId == null || tabId < 0) return [];
  try {
    const stored = await chrome.storage.session.get(sniffKey(tabId));
    return stored[sniffKey(tabId)] || [];
  } catch (_) {
    return [];
  }
}

function recordable(url) {
  return /^https?:/i.test(url) && MEDIA_RE.test(url) && !BAD_URL_RE.test(url);
}

chrome.webRequest.onBeforeRequest.addListener(
  details => {
    if (details.tabId < 0 || !recordable(details.url)) return;
    addSniff(details.tabId, details.url, "media");
  },
  { urls: ["http://*/*", "https://*/*"] }
);

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" && changeInfo.url) clearSniff(tabId);
});
chrome.tabs.onRemoved.addListener(tabId => clearSniff(tabId));

// MARK: - download interception

/// The app's `hello` / `rules` answer decides; local Settings remain the
/// fallback while the app has never answered (MDM behaves the same way).
async function shouldIntercept(item, config) {
  if (!config.captureAll) return false;
  const url = item.finalUrl || item.url;
  if (!url || BAD_URL_RE.test(url)) return false;
  // Alt/Option click: the content script asked us to leave this one alone.
  if (await consumeBrowserPass(url) || await consumeBrowserPass(item.url)) return false;

  const tracked = getTrackedResponse(item.url) || {};
  const ctype = (tracked.ctype || item.mime || "").split(";")[0].trim().toLowerCase();
  const forced = !!tracked.cdisp && /attachment/i.test(tracked.cdisp);
  const r = await loadRules();

  if (r && r.ok && typeof r.capture === "boolean") {
    if (!r.capture) return false;                 // integration or this browser off
    if (isExcluded(url, config)) return false;    // local extra exclusions still win

    const ext = getExt(url);
    if (ext === "torrent" && r.torrents === false) return false;

    const types = new Set(String(r.types || "").toLowerCase().split(/\s+/).filter(Boolean));
    if (ext && types.size && !types.has(ext) && !forced) return false;
    if (r.opened === false && !forced && browserWouldOpen(ext, ctype)) return false;

    const size = Number(item.totalBytes ?? item.fileSize ?? 0);
    // Both sides can set a floor; the stricter one wins until the popup moves
    // entirely to the app's rules in the next stage.
    const min = Math.max(Number(config.minFileSize || 0), Number(r.minKb || 0) * 1024);
    if (size > 0 && min > 0 && size < min) return false;

    const host = getHost(url).toLowerCase();
    const sites = String(r.excludedSites || "").toLowerCase()
      .split(/[\s,]+/).filter(Boolean);
    if (sites.some(site => host === site || host.endsWith("." + site))) return false;
    const addresses = (r.excludedAddresses || []).filter(Boolean);
    if (addresses.some(a => url === a || url.startsWith(a))) return false;

    if (!forced && (ctype === "text/html" || ctype === "application/xhtml+xml")) return false;
    return true;
  }

  return legacyShouldIntercept(item, config);
}

function legacyShouldIntercept(item, config) {
  if (!config.captureAll) return false;
  if (!item.url || BAD_URL_RE.test(item.url)) return false;
  if (isExcluded(item.url, config)) return false;

  // Chrome's DownloadItem exposes `totalBytes`, never `fileSize`. A download
  // often reports 0 until response headers arrive, so only skip when the size
  // is positively known and below the user's threshold.
  const size = Number(item.totalBytes ?? item.fileSize ?? 0);
  const min = Number(config.minFileSize ?? 0);
  if (size > 0 && min > 0 && size < min) return false;

  const tracked = getTrackedResponse(item.url);
  const ctype = ((tracked?.ctype) || item.mime || "").split(";")[0].trim().toLowerCase();
  const forced = !!tracked?.cdisp && /attachment/i.test(tracked.cdisp);
  // "Save page as" is the one common onCreated event that is not a file fetch.
  if (!forced && (ctype === "text/html" || ctype === "application/xhtml+xml")) return false;
  return true;
}

/// Early click: decide from the URL alone, before the browser issues a
/// request. Only known direct-file extensions qualify. Anything else keeps the
/// downloads-API path, which can see Content-Type, size and final URLs.
async function shouldTakeEarly(url) {
  const config = await getConfig();
  if (!config.captureAll) return false;
  if (!url || BAD_URL_RE.test(url)) return false;
  const ext = getExt(url);
  if (!ext || !DOWNLOAD_EXTS.has(ext)) return false;
  if (isExcluded(url, config)) return false;

  const r = await loadRules();
  if (!r || !r.ok || typeof r.capture !== "boolean") return true;
  if (!r.capture) return false;
  if (r.torrents === false && ext === "torrent") return false;
  const types = new Set(String(r.types || "").toLowerCase().split(/\s+/).filter(Boolean));
  if (types.size && !types.has(ext)) return false;
  if (r.opened === false && OPENED_EXTS.has(ext)) return false;

  const host = getHost(url).toLowerCase();
  const sites = String(r.excludedSites || "").toLowerCase()
    .split(/[\s,]+/).filter(Boolean);
  if (sites.some(site => host === site || host.endsWith("." + site))) return false;
  const addresses = (r.excludedAddresses || []).filter(Boolean);
  if (addresses.some(a => url === a || url.startsWith(a))) return false;
  return true;
}

chrome.downloads.onCreated.addListener(async item => {
  const config = await getConfig();
  if (!await shouldIntercept(item, config)) {
    bumpStat("skipped");
    return;
  }

  // Hold the browser copy while the app decides. Starting Siphon can take a
  // few seconds; without this the browser may finish (and cancel then fails).
  try { await chrome.downloads.pause(item.id); } catch (_) {}

  const tracked = getTrackedResponse(item.url) || {};
  const post = trackedPost(item.url) || {};
  const resolved = item.finalUrl || item.url;
  const dispositionName = contentDispositionFilename(tracked.cdisp);
  const filename = dispositionName || getFilename(resolved) || "";

  const result = await handoff({
    url: item.url,
    finalUrl: item.finalUrl && item.finalUrl !== item.url ? item.finalUrl : "",
    referrer: item.referrer || "",
    pageUrl: item.referrer || "",
    filename,
    nameGuessed: !dispositionName,
    size: Number(item.totalBytes ?? item.fileSize ?? tracked.clen ?? 0),
    mime: tracked.ctype || item.mime || "",
    private: !!item.incognito,
    post: post.post || "",
    postType: post.postType || "",
  });

  if (result.ok) {
    bumpStat("intercepted");
    try { await chrome.downloads.cancel(item.id); } catch (_) {}
    if (config.notifyOnCapture) {
      showCaptureNotification(filename || item.url);
    }
  } else {
    bumpStat("errors");
    // Let the browser continue; never fail silently.
    try { await chrome.downloads.resume(item.id); } catch (_) {}
    showFailureNotification(result, filename || item.url);
  }
});

function showFailureNotification(result, name) {
  let reason;
  if (result?.status === 401) {
    reason = result.error || t("bg_errTokenInvalid",
      "令牌无效，请在扩展「设置」里重新粘贴本地接口令牌");
  } else if (result?.nativeError) {
    reason = tf("bg_notifyFailedNative",
      "原生网关不可用（{error}）。请在 Siphon 设置 → 集成 填入本扩展 ID 并点「安装原生网关」，然后完全退出并重启浏览器；或在扩展「设置」里粘贴令牌走 HTTP 回退。",
      { error: result.nativeError });
  } else {
    reason = result?.error || t("bg_notifyFailedDefault", "Siphon 未运行或本地接口不可达");
  }
  try {
    const short = name.length > 40 ? name.slice(0, 37) + "..." : name;
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title: tf("bg_notifyFailedTitle", "Siphon 接管失败：{name}", { name: short }),
      message: reason,
    }, () => { void chrome.runtime.lastError; });
  } catch (_) {}
  console.warn("[Siphon] capture failed", reason, result);
}

function showCaptureNotification(filename) {
  try {
    const name = filename.length > 40 ? filename.slice(0, 37) + "..." : filename;
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title: t("bg_notifyCapturedTitle", "Siphon 已接管下载"),
      message: name,
    }, () => { void chrome.runtime.lastError; });
  } catch (_) {}
}

// MARK: - context menus

/// Links picked out of a text selection. Kept ASCII-delimited because a
/// selection is free text, not HTML.
function linksInText(text) {
  return String(text || "").match(/https?:\/\/[^\s"'<>()]+/gi) || [];
}

/// Runs in the page: every http(s) anchor, deduplicated later by the worker.
function collectPageLinks() {
  const seen = new Set();
  const out = [];
  for (const a of document.querySelectorAll("a[href]")) {
    try {
      const u = new URL(a.href, location.href);
      if (u.protocol !== "http:" && u.protocol !== "https:") continue;
      const href = u.href.split("#")[0];
      if (seen.has(href)) continue;
      seen.add(href);
      out.push(href);
    } catch (_) {}
  }
  return out;
}

/// Runs in the page: every http(s) image, with the rendered size so the popup
/// can filter out icons and tracking pixels. `srcset` candidates are included
/// because many galleries only put the full-size file there.
function collectPageImages() {
  const seen = new Set();
  const out = [];
  const add = (src, width, height) => {
    if (!src) return;
    try {
      const u = new URL(src, location.href);
      if (u.protocol !== "http:" && u.protocol !== "https:") return;
      const href = u.href.split("#")[0];
      if (seen.has(href) || out.length >= 500) return;
      seen.add(href);
      out.push({ url: href, width: width || 0, height: height || 0 });
    } catch (_) {}
  };
  for (const img of document.images) {
    const w = img.naturalWidth || img.width || 0;
    const h = img.naturalHeight || img.height || 0;
    add(img.currentSrc || img.src, w, h);
    const srcset = img.getAttribute("srcset") || "";
    for (const part of srcset.split(",")) {
      const src = part.trim().split(/\s+/)[0];
      if (src) add(src, w, h);
    }
  }
  return out;
}

function setupMenus() {
  const create = () => {
    const items = [
      { id: "siphon-link", title: t("bg_ctxLink", "用 Siphon 下载链接"), contexts: ["link"] },
      { id: "siphon-image", title: t("bg_ctxImage", "用 Siphon 下载图片"), contexts: ["image"] },
      { id: "siphon-media", title: t("bg_ctxMedia", "用 Siphon 下载媒体"), contexts: ["video", "audio"] },
      { id: "siphon-selection", title: t("bg_ctxSelection", "用 Siphon 下载选中的链接"), contexts: ["selection"] },
      { id: "siphon-page", title: t("bg_ctxPage", "用 Siphon 下载本页"), contexts: ["page"] },
      { id: "siphon-all-links", title: t("bg_ctxAllLinks", "用 Siphon 下载本页全部链接"), contexts: ["page"] },
      { id: "siphon-all-images", title: t("bg_ctxAllImages", "用 Siphon 下载本页全部图片"), contexts: ["page"] },
      { id: "siphon-browser", title: t("bg_ctxBrowser", "用浏览器下载（不接管）"),
        contexts: ["link", "image", "video", "audio"] },
    ];
    for (const item of items) {
      chrome.contextMenus.create(item, () => { void chrome.runtime.lastError; });
    }
  };
  try {
    chrome.contextMenus.removeAll(() => {
      void chrome.runtime.lastError;
      create();
    });
  } catch (_) {
    create();
  }
}

chrome.runtime.onInstalled.addListener(() => {
  setupMenus();
  loadStats();
  // Apply the one-time capture-defaults repair immediately on upgrade so the
  // popup shows the corrected state without waiting for the first download.
  getConfig();
  // Announce the extension so Settings can show the browser as connected and
  // the app can hand back its capture rules.
  refreshRules();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const pageUrl = info.pageUrl || tab?.url || "";
  const isPrivate = !!tab?.incognito;

  if (info.menuItemId === "siphon-browser") {
    const url = info.linkUrl || info.srcUrl;
    if (!url) return;
    // Leave this one to the browser: record the pass, then start it normally.
    await markBrowserPass(url);
    try {
      chrome.downloads.download({ url }, () => { void chrome.runtime.lastError; });
    } catch (_) {}
    return;
  }

  if (info.menuItemId === "siphon-all-images" && tab?.id != null) {
    let images = [];
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: collectPageImages,
      });
      images = (results && results[0] && results[0].result) || [];
    } catch (e) {
      showFailureNotification({ error: String(e) }, t("bg_errReadImages", "读取本页图片失败"));
      return;
    }
    // Drop obvious icons and tracking pixels; unknown sizes are kept.
    const urls = images
      .filter(it => !(it.width && it.height) || (it.width >= 100 && it.height >= 100))
      .map(it => it.url);
    if (!urls.length) {
      showFailureNotification({ error: t("bg_errNoImages", "没有符合条件的图片") },
        t("bg_labelPageImages", "本页图片"));
      return;
    }
    const result = await sendBatch(urls, { referrer: pageUrl, private: isPrivate });
    if (result.ok) {
      bumpStat("intercepted");
      showCaptureNotification(tf("bg_sentImages", "已发送 {sent}/{count} 张图片",
        { sent: result.sent, count: result.count }));
    } else {
      bumpStat("errors");
      showFailureNotification(result, t("bg_labelPageImages", "本页图片"));
    }
    return;
  }

  if (info.menuItemId === "siphon-all-links" && tab?.id != null) {
    let links = [];
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: collectPageLinks,
      });
      links = (results && results[0] && results[0].result) || [];
    } catch (e) {
      showFailureNotification({ error: String(e) }, t("bg_errReadLinks", "读取本页链接失败"));
      return;
    }
    const result = await sendBatch(links, { referrer: pageUrl, private: isPrivate });
    if (result.ok) {
      bumpStat("intercepted");
      showCaptureNotification(tf("bg_sentLinks", "已发送 {sent}/{count} 个链接",
        { sent: result.sent, count: result.count }));
    } else {
      bumpStat("errors");
      showFailureNotification(result, t("bg_labelPageLinks", "本页链接"));
    }
    return;
  }

  if (info.menuItemId === "siphon-selection") {
    const links = linksInText(info.selectionText);
    const result = await sendBatch(links, { referrer: pageUrl, private: isPrivate });
    if (result.ok) {
      bumpStat("intercepted");
      showCaptureNotification(tf("bg_sentLinks", "已发送 {sent}/{count} 个链接",
        { sent: result.sent, count: result.count }));
    } else {
      bumpStat("errors");
      showFailureNotification(result, t("bg_labelSelectedLinks", "选中的链接"));
    }
    return;
  }

  const url = info.linkUrl || info.srcUrl || info.pageUrl;
  if (!url) return;
  const result = await send(url, { referrer: pageUrl, private: isPrivate });
  if (result.ok) {
    bumpStat("intercepted");
    showCaptureNotification(getFilename(url) || url);
  } else {
    bumpStat("errors");
    showFailureNotification(result, getFilename(url) || url);
  }
});

// MARK: - popup messages

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "ping") {
    fetch(PING).then(async r => {
      const token = await getToken();
      reply({ ok: r.ok, tokenConfigured: !!token });
    }).catch(() => reply({ ok: false, tokenConfigured: false }));
    return true;
  }
  // The popup sends { type: "diagnose" } to probe both transports at once.
  if (msg?.type === "diagnose") {
    (async () => {
      const token = await getToken();
      const native = await sendNative({ type: "ping" });
      let appReachable = false;
      try { const r = await fetch(PING); appReachable = r.ok; } catch (_) {}
      const capture = await loadRules();
      reply({
        ok: true,
        extensionId: chrome.runtime.id,
        appReachable,
        nativeOk: !!native?.ok,
        nativeError: native?.nativeError || "",
        tokenConfigured: !!token,
        rules: capture,
      });
    })();
    return true;
  }
  // MDM popup → last 60 rows. Prefer native messaging; the HTTP fallback
  // needs a pasted token because /recent is authenticated like every other
  // control endpoint. The answer has no local paths by construction.
  if (msg?.type === "recent") {
    (async () => {
      // MDM's RecentAsk shape: the app currently answers the last 60 rows.
      const native = await sendNative({ recent: { limit: 60 } });
      if (native?.ok) { reply({ ok: true, recent: native.recent || [] }); return; }
      const token = await getToken();
      if (!token) { reply({ ok: false, error: "本地接口令牌未配置" }); return; }
      try {
        const response = await fetch("http://127.0.0.1:17801/recent", {
          headers: { Authorization: "Bearer " + token },
        });
        const body = await response.json();
        reply({ ok: response.ok, recent: body.recent || [] });
      } catch (error) {
        reply({ ok: false, error: String(error) });
      }
    })();
    return true;
  }
  // "Don't capture this site any more" from the This-page tab.
  if (msg?.type === "setSiteCapture") {
    (async () => {
      const config = await getConfig();
      const host = String(msg.host || "").trim().toLowerCase();
      if (!host) { reply({ ok: false }); return; }
      let hosts = (config.excludeHosts || []).filter(h => h !== host);
      if (msg.enabled === false) hosts.push(host);
      await chrome.storage.local.set({ excludeHosts: hosts });
      reply({ ok: true, excludeHosts: hosts });
    })();
    return true;
  }
  // Pause / resume / remove from the Downloads tab. Uses MDM's downloadAct
// envelope; the answer never carries local paths.
  if (msg?.type === "downloadAct") {
    (async () => {
      const act = String(msg.act || "");
      const id = String(msg.id || "");
      if (!act || !id) { reply({ ok: false, error: "missing act/id" }); return; }
      const native = await sendNative({ downloadAct: { act, id } });
      if (native?.ok) { reply(native); return; }
      const token = await getToken();
      if (!token) { reply({ ok: false, error: "本地接口令牌未配置" }); return; }
      try {
        const response = await fetch("http://127.0.0.1:17801/act", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: "Bearer " + token,
          },
          body: JSON.stringify({ act, id }),
        });
        reply(await response.json());
      } catch (error) {
        reply({ ok: false, error: String(error) });
      }
    })();
    return true;
  }
  // Alt/Option was held on a click: let the browser keep that download.
  if (msg?.type === "browserPass") {
    markBrowserPass(String(msg.url || "")).then(() => reply({ ok: true }));
    return true;
  }
  if (msg?.type === "refreshRules") {
    refreshRules().then(r => reply({ ok: !!(r && r.ok), rules: r || null }));
    return true;
  }
  if (msg?.type === "getToken") {
    getToken().then(t => reply({ ok: true, token: t || "" }));
    return true;
  }
  if (msg?.type === "setToken") {
    const value = typeof msg.token === "string" ? msg.token.trim() : "";
    chrome.storage.local.set({ apiToken: value }).then(() => {
      apiToken = value || null;
      reply({ ok: true });
    }).catch(e => reply({ ok: false, error: String(e) }));
    return true;
  }
  if (msg?.type === "sniffed") {
    listSniff(msg.tabId).then(items => reply({ ok: true, items }));
    return true;
  }
  if (msg?.type === "send") {
    send(msg.url, { referrer: msg.referrer || msg.referer || "",
                      filename: msg.filename || "" })
      .then(result => {
        if (result.ok) bumpStat("intercepted");
        reply(result);
      });
    return true;
  }
  if (msg?.type === "clearSniffed") {
    clearSniff(msg.tabId).then(() => reply({ ok: true }));
    return true;
  }
  // Early click (page.js): the page has already held the navigation, so this
  // is the only chance to use a single-use URL. A refusal records a browser
  // pass first: the page will start a normal download and the downloads
  // listener must not race it with a second hand-off.
  if (msg?.type === "earlyClick") {
    (async () => {
      const url = String(msg.url || "");
      const tab = _sender?.tab;
      if (!(await shouldTakeEarly(url))) {
        reply({ ok: false, taken: false });
        return;
      }
      const result = await send(url, {
        referrer: msg.referrer || tab?.url || "",
        explicit: true,
        private: !!tab?.incognito,
      });
      if (result.ok) {
        bumpStat("intercepted");
      } else {
        bumpStat("errors");
        await markBrowserPass(url);
        showFailureNotification(result, getFilename(url) || url);
      }
      reply({ ok: !!result.ok, error: result.error || "" });
    })();
    return true;
  }
  // Floating video button (page.js): send the tab's sniffed stream, preferring
  // HLS/DASH manifests, then fall back to the video's own http(s) source.
  if (msg?.type === "pageMedia") {
    (async () => {
      const tab = _sender?.tab;
      const pageUrl = msg.pageUrl || tab?.url || "";
      let urls = [];
      if (tab?.id != null) urls = (await listSniff(tab.id)).map(item => item.url);
      const direct = String(msg.src || "");
      if (/^https?:/i.test(direct)) urls.push(direct.split("#")[0]);
      urls = [...new Set(urls.filter(u => /^https?:/i.test(u)))];
      if (!urls.length && !/^https?:/i.test(direct)) {
        reply({ ok: false, error: t("bg_errNoMedia", "未嗅探到媒体流") });
        return;
      }
      // Prefer the oldest manifest: HLS/DASH pages fetch the master playlist
      // before the variants, and the newest entry is often just one variant.
      const manifests = urls.filter(u => /\.(m3u8|mpd)(\?|#|$)/i.test(u));
      let chosen;
      if (manifests.length) {
        chosen = [manifests[manifests.length - 1]];
      } else if (/^https?:/i.test(direct)) {
        chosen = [direct];
      } else {
        chosen = urls.slice(0, 3);
      }
      const result = await sendBatch(chosen, {
        referrer: pageUrl,
        private: !!tab?.incognito,
      });
      if (result.ok) bumpStat("intercepted");
      reply(result);
    })();
    return true;
  }
  // This-page image grabber: collect `<img>` / `srcset` candidates with their
  // rendered size, then hand the chosen ones over as one linksPart batch.
  if (msg?.type === "images") {
    (async () => {
      const tabId = Number(msg.tabId);
      if (!Number.isFinite(tabId) || tabId < 0) {
        reply({ ok: false, items: [], error: "没有可读取的标签页" });
        return;
      }
      try {
        const results = await chrome.scripting.executeScript({
          target: { tabId },
          func: collectPageImages,
        });
        const items = (results && results[0] && results[0].result) || [];
        reply({ ok: true, items });
      } catch (error) {
        reply({ ok: false, items: [], error: String(error) });
      }
    })();
    return true;
  }
  if (msg?.type === "sendImages") {
    sendBatch(msg.urls || [], {
      referrer: msg.referrer || "",
      private: !!msg.private,
    }).then(result => {
      if (result.ok) bumpStat("intercepted");
      reply(result);
    });
    return true;
  }
  // Read-only proxy summary for the Settings tab. `system` (or no proxy API)
  // means the app keeps its own Options proxy, exactly like a download.
  if (msg?.type === "getProxy") {
    proxyContext(false)
      .then(value => reply({ ok: true, ...value }))
      .catch(error => reply({ ok: false, error: String(error) }));
    return true;
  }
  if (msg?.type === "getConfig") {
    getConfig().then(config => reply({ ok: true, config }));
    return true;
  }
  if (msg?.type === "setConfig") {
    chrome.storage.local.set(msg.config || {}).then(() => reply({ ok: true }));
    return true;
  }
  if (msg?.type === "getStats") {
    loadStats().then(() => reply({ ok: true, stats }));
    return true;
  }
  if (msg?.type === "resetStats") {
    stats = { intercepted: 0, skipped: 0, media: 0, errors: 0 };
    saveStats().then(() => reply({ ok: true, stats }));
    return true;
  }
});

chrome.runtime.onStartup.addListener(() => {
  setupMenus();
  loadStats();
  getConfig();
  refreshRules();
});

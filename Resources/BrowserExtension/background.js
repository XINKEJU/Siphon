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
const PING = "http://127.0.0.1:17801/ping";
const NATIVE_HOST = "com.xinkeju.siphon";

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
  minFileSize: 1048576,
  excludeHosts: [],
  excludeExts: [],
  notifyOnCapture: true,
  interceptMedia: true,
  interceptDocuments: true,
  interceptArchives: true,
  interceptInstallers: true,
};

async function getConfig() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  const config = { ...DEFAULTS };
  for (const [k, v] of Object.entries(stored)) {
    if (v !== undefined) config[k] = v;
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

function sendNative(payload) {
  return new Promise(resolve => {
    let done = false;
    let port;
    try {
      port = chrome.runtime.connectNative(NATIVE_HOST);
    } catch (_) {
      resolve({ ok: false });
      return;
    }
    const timer = setTimeout(() => finish({ ok: false }), 4000);
    function finish(value) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { port.disconnect(); } catch (_) {}
      resolve(value || { ok: false });
    }
    port.onMessage.addListener(msg => finish(msg));
    port.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      finish({ ok: false });
    });
    port.postMessage(payload);
  });
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

async function sendHTTP(payload) {
  try {
    const token = await getToken();
    const r = await fetch(ENDPOINT, {
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
        error: token ? "令牌无效或已轮换，请在 Siphon 设置 → 集成 复制后重新粘贴"
                     : "缺少令牌，请在扩展「设置」中粘贴 Siphon 的本地接口令牌",
      };
    }
    return { ok: r.ok, via: "http", status: r.status };
  } catch (e) {
    console.warn("[Siphon] app not reachable", e);
    return { ok: false };
  }
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    if (!cookies || !cookies.length) return "";
    return cookies.map(c => `${c.name}=${c.value}`).join("; ");
  } catch (_) {
    return "";
  }
}

// MARK: - sending

async function send(url, { headers = {}, referer = "", useCookies = true, filename = "" } = {}) {
  if (!url || BAD_URL_RE.test(url)) return { ok: false };
  const merged = { ...headers };
  if (referer && !hasHeader(merged, "referer")) merged.Referer = referer;
  if (useCookies && !hasHeader(merged, "cookie")) {
    const cookie = await cookieHeader(url);
    if (cookie) merged.Cookie = cookie;
  }
  const payload = { type: "add", url };
  if (filename) payload.filename = filename;
  if (Object.keys(merged).length) payload.headers = merged;
  const viaNative = await sendNative(payload);
  if (viaNative && viaNative.ok) return { ok: true, via: "native" };
  return sendHTTP(payload);
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

chrome.webRequest.onHeadersReceived.addListener(
  details => {
    if (details.tabId < 0) return;
    if (details.type === "main_frame" || details.type === "sub_frame") {
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
  },
  { urls: ["http://*/*", "https://*/*"] },
  ["responseHeaders"]
);

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

async function shouldIntercept(item, config) {
  if (!config.captureAll) return false;
  if (!item.url || BAD_URL_RE.test(item.url)) return false;
  if (isExcluded(item.url, config)) return false;

  if (item.fileSize && item.fileSize > 0 && item.fileSize < config.minFileSize) {
    return false;
  }

  const tracked = getTrackedResponse(item.url);
  if (tracked) {
    if (isSkippableCType(tracked.ctype)) return false;
    if (isDownloadableCType(tracked.ctype)) return true;
    if (tracked.cdisp && /attachment/i.test(tracked.cdisp)) return true;
  }

  if (isDownloadableExt(item.url)) return true;

  if (item.mime) {
    if (isDownloadableCType(item.mime)) return true;
    if (isSkippableCType(item.mime)) return false;
  }

  if (item.filename) {
    const ext = item.filename.split(".").pop()?.toLowerCase();
    if (ext && (DOWNLOAD_EXTS.has(ext) || MEDIA_EXTS.has(ext))) return true;
  }

  return false;
}

chrome.downloads.onCreated.addListener(async item => {
  const config = await getConfig();
  if (!await shouldIntercept(item, config)) {
    bumpStat("skipped");
    return;
  }

  const headers = sanitizeHeaders(item.requestHeaders);
  const referer = item.referrer || "";
  const filename = getFilename(item.url) || item.filename || "";

  const result = await send(item.url, { headers, referer, filename });
  if (result.ok) {
    bumpStat("intercepted");
    try { await chrome.downloads.cancel(item.id); } catch (_) {}
    if (config.notifyOnCapture) {
      showCaptureNotification(filename || item.url);
    }
  } else {
    bumpStat("errors");
  }
});

function showCaptureNotification(filename) {
  try {
    const name = filename.length > 40 ? filename.slice(0, 37) + "..." : filename;
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title: "Siphon 已接管下载",
      message: name,
    }, () => { void chrome.runtime.lastError; });
  } catch (_) {}
}

// MARK: - context menus

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "siphon-send-link",
    title: "用 Siphon 下载",
    contexts: ["link", "video", "audio", "image"],
  });
  chrome.contextMenus.create({
    id: "siphon-send-page",
    title: "用 Siphon 下载本页",
    contexts: ["page"],
  });
  loadStats();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const url = info.linkUrl || info.srcUrl || info.pageUrl;
  if (!url) return;
  const result = await send(url, { referer: info.pageUrl || "" });
  if (result.ok) {
    bumpStat("intercepted");
    showCaptureNotification(getFilename(url) || url);
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
    send(msg.url, { referer: msg.referer || "", filename: msg.filename || "" })
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
  loadStats();
});

// Manifest V3 service worker for the Siphon connector (v2).
//
// Two ways to reach the app:
//   1. Native Messaging via the SiphonNM gateway (works without the local
//      control interface; installed from Siphon → Settings → 集成).
//   2. Loopback HTTP fallback (http://127.0.0.1:17801/add + /ping token).
//
// It also sniffs media URLs per tab (m3u8 / mpd / mp4 / …) and attaches the
// browser's cookies so logged-in direct links download correctly.
const ENDPOINT = "http://127.0.0.1:17801/add";
const PING = "http://127.0.0.1:17801/ping";
const NATIVE_HOST = "com.xinkeju.siphon";

const MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|webm|mkv|ts|mp3|m4a|aac|flac|ogg|wav|mov)(\?|#|$)/i;
const BAD_URL_RE = /^(chrome|chrome-extension|edge|about|data|blob|javascript):/i;

const HOP_BY_HOP = new Set([
  "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding",
  "upgrade", "te", "trailer", "content-length", "content-encoding", "vary",
  "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest",
  "sec-fetch-user", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
  "if-modified-since", "if-none-match", "range", "accept-encoding",
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
      // Reading lastError suppresses the "Unchecked runtime.lastError" warning
      // when the gateway is not installed or the app is not running.
      void chrome.runtime.lastError;
      finish({ ok: false });
    });
    port.postMessage(payload);
  });
}

// MARK: - HTTP fallback token

let apiToken = null;
async function getToken() {
  if (apiToken) return apiToken;
  const stored = await chrome.storage.local.get("apiToken");
  apiToken = stored.apiToken || null;
  if (apiToken) return apiToken;
  try {
    const r = await fetch(PING);
    if (r.ok) {
      const j = await r.json();
      if (j.token) {
        apiToken = j.token;
        await chrome.storage.local.set({ apiToken });
      }
    }
  } catch (_) {}
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
      apiToken = null;
      const retryToken = await getToken();
      const retry = await fetch(ENDPOINT, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(retryToken ? { Authorization: `Bearer ${retryToken}` } : {}),
        },
        body: JSON.stringify(payload),
      });
      return { ok: retry.ok, via: "http", status: retry.status };
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

async function send(url, { headers = {}, referer = "", useCookies = true } = {}) {
  if (!url || BAD_URL_RE.test(url)) return { ok: false };
  const merged = { ...headers };
  if (referer && !hasHeader(merged, "referer")) merged.Referer = referer;
  if (useCookies && !hasHeader(merged, "cookie")) {
    const cookie = await cookieHeader(url);
    if (cookie) merged.Cookie = cookie;
  }
  const payload = { type: "add", url };
  if (Object.keys(merged).length) payload.headers = merged;
  // Native Messaging first (no local interface needed), then loopback HTTP.
  const viaNative = await sendNative(payload);
  if (viaNative && viaNative.ok) return { ok: true, via: "native" };
  return sendHTTP(payload);
}

// MARK: - media sniffing (per tab, session storage)

const sniffQueues = new Map();

function sniffKey(tabId) { return `sniff:${tabId}`; }

function addSniff(tabId, url) {
  const prev = sniffQueues.get(tabId) || Promise.resolve();
  const next = prev.then(() => doAddSniff(tabId, url)).catch(() => {});
  sniffQueues.set(tabId, next);
  return next;
}

async function doAddSniff(tabId, url) {
  const key = sniffKey(tabId);
  const stored = await chrome.storage.session.get(key);
  let list = stored[key] || [];
  const isSegment = /\.ts(\?|#|$)/i.test(url);
  // A playlist is already a much better target than its hundreds of .ts chunks.
  if (isSegment && list.some(item => /\.m3u8(\?|#|$)/i.test(item.url))) return;
  list = list.filter(item => item.url !== url);
  list.unshift({ url, at: Date.now() });
  list = list.slice(0, 50);
  await chrome.storage.session.set({ [key]: list });
  updateBadge(tabId, list.length);
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
    addSniff(details.tabId, details.url);
  },
  { urls: ["http://*/*", "https://*/*"] }
);

// A main-frame navigation starts a new media session: drop the old list.
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" && changeInfo.url) clearSniff(tabId);
});
chrome.tabs.onRemoved.addListener(tabId => clearSniff(tabId));

// MARK: - menus / downloads

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "siphon-send-link",
    title: "用 Siphon 下载",
    contexts: ["link", "video", "audio", "image"],
  });
});

chrome.contextMenus.onClicked.addListener(info => {
  send(info.linkUrl || info.srcUrl || info.pageUrl);
});

chrome.downloads.onCreated.addListener(async item => {
  const enabled = (await chrome.storage.local.get("captureAll")).captureAll ?? false;
  if (!enabled || !item.url) return;
  const headers = sanitizeHeaders(item.requestHeaders);
  await send(item.url, { headers, referer: item.referrer || "" });
  try { await chrome.downloads.cancel(item.id); } catch (_) {}
});

// MARK: - popup messages

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "ping") {
    fetch(PING).then(async r => {
      if (r.ok) {
        const j = await r.json();
        if (j.token) {
          apiToken = j.token;
          await chrome.storage.local.set({ apiToken });
        }
      }
      reply({ ok: r.ok });
    }).catch(() => reply({ ok: false }));
    return true;
  }
  if (msg?.type === "sniffed") {
    listSniff(msg.tabId).then(items => reply({ ok: true, items }));
    return true;
  }
  if (msg?.type === "send") {
    send(msg.url).then(result => reply(result));
    return true;
  }
  if (msg?.type === "clearSniffed") {
    clearSniff(msg.tabId).then(() => reply({ ok: true }));
    return true;
  }
});

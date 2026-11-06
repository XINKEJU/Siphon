// Manifest V3 service worker for the Siphon connector.
// Load unpacked in chrome://extensions (Developer mode), then enable
// "本地控制接口" in Siphon → Settings → 集成.
const ENDPOINT = "http://127.0.0.1:17801/add";
const PING = "http://127.0.0.1:17801/ping";

// Hop-by-hop and security headers are meaningless (or harmful) when replayed by
// the native engine; everything else — cookies are NOT included here, the app
// has no cookie jar — is passed through so servers that gate on UA/Referer/
// Accept see the same request the browser made.
const HOP_BY_HOP = new Set([
  "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding",
  "upgrade", "te", "trailer", "content-length", "content-encoding", "vary",
  "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest",
  "sec-fetch-user", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
  "if-modified-since", "if-none-match", "range", "cookie", "accept-encoding",
]);

function sanitizeHeaders(raw) {
  const out = {};
  for (const h of raw ?? []) {
    const name = (h.name || "").toLowerCase().trim();
    const value = (h.value || "").trim();
    if (!name || !value) continue;
    if (HOP_BY_HOP.has(name) || name.startsWith("sec-") || name.startsWith("proxy-")) continue;
    // CRLF injection guard mirrors the native side's sanitization.
    if (/[\r\n]/.test(value)) continue;
    out[h.name] = value;
  }
  return out;
}

async function send(url, { headers = {}, referer = "" } = {}) {
  if (!url) return;
  if (/^(chrome|edge|about|data|blob|javascript):/i.test(url)) return;
  try {
    const payload = { url };
    if (Object.keys(headers).length || referer) {
      payload.headers = { ...headers, ...(referer ? { Referer: referer } : {}) };
    }
    const r = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    console.log("[Siphon] sent", url, r.status);
  } catch (e) {
    console.warn("[Siphon] app not running?", e);
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "siphon-send-link",
    title: "用 Siphon 下载",
    contexts: ["link", "video", "audio", "image"],
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  send(info.linkUrl || info.srcUrl || info.pageUrl);
});

chrome.downloads.onCreated.addListener(async (item) => {
  const enabled = (await chrome.storage.local.get("captureAll")).captureAll ?? false;
  if (!enabled || !item.url) return;
  // Hand the URL to the native app (with the browser's own request headers and
  // referrer replayed) and cancel the browser's download. requestHeaders is
  // Chrome 111+; older builds simply fall back to Referer only.
  const headers = sanitizeHeaders(item.requestHeaders);
  await send(item.url, { headers, referer: item.referrer || "" });
  try { await chrome.downloads.cancel(item.id); } catch (_) {}
});

// The popup can call this to test connectivity.
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "ping") {
    fetch(PING).then(r => reply({ ok: r.ok })).catch(() => reply({ ok: false }));
    return true; // keep the message channel open for the async reply
  }
});

// Manifest V3 service worker for the Siphon connector.
// Load unpacked in chrome://extensions (Developer mode), then enable
// "本地控制接口" in Siphon → Settings → 集成.
const ENDPOINT = "http://127.0.0.1:17801/add";
const PING = "http://127.0.0.1:17801/ping";

async function send(url) {
  if (!url) return;
  if (/^(chrome|edge|about|data|blob|javascript):/i.test(url)) return;
  try {
    const r = await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
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
  // Hand the URL to the native app and cancel the browser's own download.
  await send(item.url);
  try { await chrome.downloads.cancel(item.id); } catch (_) {}
});

// The popup can call this to test connectivity.
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "ping") {
    fetch(PING).then(r => reply({ ok: r.ok })).catch(() => reply({ ok: false }));
    return true; // keep the message channel open for the async reply
  }
});

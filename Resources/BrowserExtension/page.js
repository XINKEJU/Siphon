// Runs at document_start on every page.
//
// Two jobs:
//   1. "Keep in browser": holding Option/Alt while clicking a link or media
//      tells the worker to leave the resulting download alone. That decision
//      must be recorded before Chrome starts the download, which is why this
//      listener is in the page and not in the popup.
//   2. Floating "send to Siphon" button over each video, in MDM's style: it
//      follows the video, keeps its own state (sending / sent / failed) and
//      asks the worker for the tab's sniffed HLS/DASH stream.
(() => {
  const api = (typeof browser !== "undefined" && browser.runtime) ? browser : chrome;
  const t = (key, fallback) => {
    try {
      return (api.i18n && api.i18n.getMessage(key)) || fallback;
    } catch (_) {
      return fallback;
    }
  };

  function urlFromEvent(event) {
    const target = event.target;
    if (!target || !target.closest) return "";
    const anchor = target.closest("a[href]");
    if (anchor && /^https?:/i.test(anchor.href)) return anchor.href;
    const media = target.closest("video, audio, img, source");
    if (media) {
      const src = media.currentSrc || media.src || media.getAttribute("src") || "";
      try {
        const url = new URL(src, location.href);
        if (/^https?:/i.test(url.href)) return url.href.split("#")[0];
      } catch (_) {}
    }
    return "";
  }

  function notePass(event) {
    if (!event.altKey) return;            // Option on macOS, Alt elsewhere
    const url = urlFromEvent(event);
    if (!url) return;
    try {
      api.runtime.sendMessage({ type: "browserPass", url });
    } catch (_) {}
  }

  window.addEventListener("mousedown", notePass, true);
  window.addEventListener("auxclick", notePass, true);
  window.addEventListener("click", notePass, true);

  // MARK: - early interception
  //
  // Known file links are taken before the browser issues the request. Some
  // download URLs are single-use (signed tokens), so letting Chrome fetch the
  // file first and cancelling afterwards would burn the link. If Siphon does
  // not take it, the page navigates so the browser downloads as usual.

  const EARLY_PATH_RE = new RegExp(
    "\\.(zip|rar|7z|tar|gz|bz2|xz|tgz|tbz2|lz|lzma|pdf|doc|docx|xls|xlsx|ppt|pptx"
    + "|odt|ods|odp|rtf|epub|mobi|azw|azw3|djvu|exe|msi|dmg|pkg|deb|rpm|apk|ipa"
    + "|appimage|iso|img|vmdk|vdi|vhd|torrent)$", "i");

  function earlyTarget(event) {
    if (!event.isTrusted || event.defaultPrevented || event.button !== 0) return null;
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return null;
    const target = event.target;
    const anchor = target && target.closest ? target.closest("a[href]") : null;
    if (!anchor) return null;
    const raw = anchor.href;
    if (!/^https?:/i.test(raw)) return null;
    let parsed;
    try { parsed = new URL(raw); } catch (_) { return null; }
    if (!EARLY_PATH_RE.test(parsed.pathname)) return null;
    return {
      url: raw,
      blank: (anchor.getAttribute("target") || "").toLowerCase() === "_blank",
    };
  }

  function restoreNavigation(hit) {
    try {
      if (hit.blank) {
        const opened = window.open(hit.url, "_blank", "noopener");
        if (opened) return;
      }
      location.assign(hit.url);
    } catch (_) {
      try { location.href = hit.url; } catch (_) {}
    }
  }

  // MARK: - page toast
  //
  // The early-click hand-off can take a moment while Siphon starts. A small
  // non-blocking toast tells the user the click was not ignored, and doubles
  // as the "not taken over" notice when the browser gets the file instead.

  let toastHost = null;
  let toastBox = null;
  let toastTimer = 0;
  let earlyBusy = false;

  function ensureToast() {
    if (toastHost && toastHost.isConnected) return;
    toastHost = document.createElement("div");
    toastHost.id = "siphon-toast";
    toastHost.style.cssText =
      "position:fixed;right:16px;bottom:16px;z-index:2147483647;pointer-events:none;";
    const root = toastHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      .box {
        max-width: 320px;
        padding: 8px 12px;
        border-radius: 8px;
        background: rgba(28, 28, 30, 0.94);
        color: #fff;
        font: 500 12px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
        opacity: 0;
        transform: translateY(4px);
        transition: opacity 0.16s ease, transform 0.16s ease;
      }
      .box[data-tone="ok"] { background: #248a3d; }
      .box[data-tone="fail"] { background: #c93400; }
      .box.show { opacity: 1; transform: none; }
    `;
    toastBox = document.createElement("div");
    toastBox.className = "box";
    root.appendChild(style);
    root.appendChild(toastBox);
    (document.body || document.documentElement).appendChild(toastHost);
  }

  function showToast(text, tone = "busy", hold = 0) {
    ensureToast();
    toastBox.textContent = text;
    toastBox.dataset.tone = tone;
    toastBox.classList.add("show");
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = 0; }
    if (hold > 0) {
      toastTimer = setTimeout(() => {
        toastTimer = 0;
        toastBox.classList.remove("show");
      }, hold);
    }
  }

  window.addEventListener("click", async event => {
    const hit = earlyTarget(event);
    if (!hit) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (earlyBusy) return;               // a hand-off is already in flight
    earlyBusy = true;
    showToast(t("page_toastSending", "正在发送到 Siphon…"));
    let reply = null;
    try {
      reply = await api.runtime.sendMessage({
        type: "earlyClick",
        url: hit.url,
        referrer: location.href,
      });
    } catch (_) {}
    earlyBusy = false;
    if (reply && reply.ok) {
      showToast(t("page_toastSent", "已发送到 Siphon"), "ok", 1600);
      return;                            // Siphon accepted; the browser stays put.
    }
    showToast(t("page_toastNoResponse", "Siphon 未响应，已交给浏览器"), "fail", 1800);
    restoreNavigation(hit);
  }, true);

  // MARK: - floating video button

  const BUTTON_ID = "siphon-video-button";
  const MIN_WIDTH = 220;
  const MIN_HEIGHT = 120;
  const IDLE_LABEL = t("page_btnIdle", "发送到 Siphon");

  const entries = new Map();   // video → { host, button, state, timer }
  const marked = new WeakSet();
  let positionFrame = 0;
  let scanFrame = 0;
  let ticker = 0;

  function videoSource(video) {
    const direct = video.currentSrc || video.src
      || (video.querySelector && video.querySelector("source")
        ? video.querySelector("source").src : "");
    return /^https?:/i.test(direct || "") ? direct.split("#")[0] : "";
  }

  function isCandidate(video) {
    if (!video || !(video instanceof HTMLVideoElement)) return false;
    if (videoSource(video)) return true;
    if (video.readyState > 0) return true;
    return !!(video.querySelector && video.querySelector("source"));
  }

  function setState(entry, state, label) {
    entry.state = state;
    entry.button.dataset.state = state;
    entry.button.textContent = label;
    if (entry.timer) { clearTimeout(entry.timer); entry.timer = 0; }
    if (state === "sent" || state === "failed") {
      entry.timer = setTimeout(() => {
        entry.timer = 0;
        setState(entry, "idle", IDLE_LABEL);
      }, 2200);
    }
  }

  /// EME media cannot be fetched by a downloader; say so instead of letting
  /// the click fail with a generic "未找到媒体".
  function markDrm(entry) {
    if (!entry || entry.state === "drm") return;
    if (entry.timer) { clearTimeout(entry.timer); entry.timer = 0; }
    entry.state = "drm";
    entry.button.dataset.state = "drm";
    entry.button.textContent = t("page_btnDrm", "受 DRM 保护");
    entry.button.title = t("page_btnDrmTitle", "受 DRM 保护的视频无法下载");
    entry.button.disabled = true;
  }

  function createEntry(video) {
    const host = document.createElement("div");
    host.id = BUTTON_ID;
    host.style.cssText = "position:fixed;z-index:2147483647;display:none;pointer-events:auto;"
      + "transform:translateX(-100%);";
    const root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      button {
        all: unset;
        box-sizing: border-box;
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 7px 12px;
        border-radius: 999px;
        background: #0071e3;
        color: #fff;
        font: 600 12px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        white-space: nowrap;
        cursor: pointer;
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.28);
        transition: background 0.15s ease;
      }
      button:hover { background: #0077ed; }
      button[data-state="sent"] { background: #34c759; }
      button[data-state="failed"] { background: #ff3b30; }
      button[data-state="drm"] { background: #8e8e93; cursor: not-allowed; }
    `;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = IDLE_LABEL;
    button.title = t("page_btnTitle", "把此视频的媒体流发送到 Siphon");
    button.dataset.state = "idle";
    root.appendChild(style);
    root.appendChild(button);

    const entry = { host, button, state: "idle", timer: 0 };
    const stop = event => event.stopPropagation();
    button.addEventListener("mousedown", stop);
    button.addEventListener("auxclick", stop);
    button.addEventListener("click", async event => {
      event.preventDefault();
      event.stopPropagation();
      if (entry.state === "sending") return;
      setState(entry, "sending", t("page_btnSending", "发送中…"));
      let reply = null;
      try {
        reply = await api.runtime.sendMessage({
          type: "pageMedia",
          pageUrl: location.href,
          src: videoSource(video),
        });
      } catch (_) {}
      if (reply && reply.ok) {
        setState(entry, "sent", t("page_btnSent", "已发送"));
      } else {
        setState(entry, "failed", reply && reply.error
          ? t("page_btnNoMedia", "未找到媒体")
          : t("page_btnFailed", "发送失败"));
      }
    });

    (document.body || document.documentElement).appendChild(host);
    entries.set(video, entry);
    marked.add(video);
    ensureTicker();
    return entry;
  }

  function attach(video) {
    if (!isCandidate(video) || marked.has(video)) return;
    createEntry(video);
    if (video.mediaKeys) markDrm(entries.get(video));
    schedulePosition();
  }

  function scan() {
    for (const video of document.querySelectorAll("video")) attach(video);
  }

  function scheduleScan() {
    if (scanFrame) return;
    scanFrame = requestAnimationFrame(() => {
      scanFrame = 0;
      scan();
    });
  }

  function schedulePosition() {
    if (positionFrame) return;
    positionFrame = requestAnimationFrame(() => {
      positionFrame = 0;
      positionAll();
    });
  }

  function positionAll() {
    const fullscreen = document.fullscreenElement;
    for (const [video, entry] of entries) {
      if (!video.isConnected) {
        entry.host.remove();
        entries.delete(video);
        continue;
      }
      const rect = video.getBoundingClientRect();
      const visible = rect.width >= MIN_WIDTH && rect.height >= MIN_HEIGHT
        && rect.bottom > 0 && rect.top < window.innerHeight
        && rect.right > 0 && rect.left < window.innerWidth
        && fullscreen !== video;
      if (!visible) {
        entry.host.style.display = "none";
        continue;
      }
      entry.host.style.display = "block";
      entry.host.style.left = Math.round(rect.right - 12) + "px";
      entry.host.style.top = Math.round(rect.top + 12) + "px";
    }
  }

  // A fullscreen container hides anything left in <body>; re-parent the
  // buttons into it. Fullscreen on the <video> itself cannot host overlays,
  // so the button stays hidden there.
  function rehost() {
    const target = document.fullscreenElement;
    for (const [video, entry] of entries) {
      const parent = target && target !== video && target.contains(video)
        ? target : (document.body || document.documentElement);
      if (entry.host.parentNode !== parent) parent.appendChild(entry.host);
    }
    schedulePosition();
  }

  function ensureTicker() {
    if (ticker) return;
    ticker = setInterval(() => {
      if (!entries.size) {
        clearInterval(ticker);
        ticker = 0;
        return;
      }
      scan();
      positionAll();
    }, 800);
  }

  if (document.documentElement) {
    new MutationObserver(scheduleScan).observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  }
  document.addEventListener("play", event => {
    if (event.target instanceof HTMLVideoElement) {
      attach(event.target);
      schedulePosition();
    }
  }, true);
  document.addEventListener("encrypted", event => {
    const video = event.target;
    if (!(video instanceof HTMLVideoElement)) return;
    attach(video);
    markDrm(entries.get(video));
  }, true);
  document.addEventListener("fullscreenchange", rehost);
  window.addEventListener("scroll", schedulePosition, true);
  window.addEventListener("resize", schedulePosition, true);
  scan();
  document.addEventListener("DOMContentLoaded", scan);
})();
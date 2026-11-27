// popup.js — tabbed UI for Siphon v3 extension

const t = (key, fallback) => (chrome.i18n && chrome.i18n.getMessage(key)) || fallback;

// Fill `{name}` tokens in a translated string after chrome.i18n lookup.
const tf = (key, fallback, vars) => {
  let text = t(key, fallback);
  for (const [name, value] of Object.entries(vars || {})) {
    text = text.split(`{${name}}`).join(String(value));
  }
  return text;
};

// Simplified Chinese source text in popup.html -> message key. Matched after
// trimming a text node (or a placeholder/title attribute). A missing key keeps
// the original Chinese, so a browser without _locales still shows the old UI.
const SOURCE_KEYS = {
  "检查连接…": "popup_status_checking",
  "搜索下载": "popup_searchPlaceholder",
  "刷新": "popup_refresh",
  "清空已完成": "popup_clearCompleted",
  "本次统计": "popup_statsTitle",
  "已拦截": "popup_statIntercepted",
  "已跳过": "popup_statSkipped",
  "嗅探媒体": "popup_statMedia",
  "错误": "popup_statErrors",
  "重置统计": "popup_resetStats",
  "本页媒体": "popup_mediaSectionTitle",
  "本站不再接管": "popup_siteDisable",
  "嗅探到的媒体": "popup_sniffedTitle",
  "发送全部": "popup_sendAll",
  "清空": "popup_clear",
  "也可右键点击链接，选择「用 Siphon 下载」。受 DRM 保护的视频无法下载，浮钮会直接标注。": "popup_mediaHelp",
  "本页图片": "popup_imagesTitle",
  "最小宽度 px": "popup_imageMinWidth",
  "最小高度 px": "popup_imageMinHeight",
  "收集图片": "popup_collectImages",
  "尚未收集图片": "popup_imagesNotCollected",
  "发送选中": "popup_sendSelected",
  "全选": "popup_selectAll",
  "只收集 http(s) 图片；小图标可用宽高过滤掉。": "popup_imagesHelp",
  "接管规则": "popup_rulesTitle",
  "接管浏览器全部下载": "popup_captureAll",
  "拦截时显示通知": "popup_notifyOnCapture",
  "扩展优先执行 Siphon 下发的接管规则（文件类型、站点、最小体积等）；这里的开关是本地兜底。只有 Siphon 接受任务后，扩展才会取消浏览器下载；失败时浏览器下载继续并弹出提示。": "popup_rulesHelp",
  "本机连接": "popup_connectionTitle",
  "发送到本机": "popup_sendToLocal",
  "检查中…": "popup_checking",
  "浏览器代理": "popup_browserProxy",
  "读取中…": "popup_reading",
  "刷新状态": "popup_refreshStatus",
  "打开 Siphon 设置": "popup_openAppSettings",
  "连接诊断": "popup_diagnosticsTitle",
  "复制扩展 ID": "popup_copyExtensionId",
  "把扩展 ID 粘贴到 Siphon 设置 → 集成 →「扩展 ID」，点「安装原生网关」，然后完全退出并重启浏览器（浏览器只在启动时读取网关清单）。": "popup_diagnosticsHelp",
  "文件大小过滤": "popup_sizeFilterTitle",
  "最小文件大小（MB）": "popup_minFileSize",
  "0 表示不限制。小于此大小的文件不拦截，由浏览器直接下载。": "popup_sizeFilterHelp",
  "排除站点": "popup_excludeHostsTitle",
  "例如：youtube.com": "popup_excludeHostPlaceholder",
  "添加": "popup_add",
  "排除站点上的下载将由浏览器处理。": "popup_excludeHostsHelp",
  "排除扩展名": "popup_excludeExtsTitle",
  "例如：html": "popup_excludeExtPlaceholder",
  "本地接口令牌（仅 HTTP 回退需要）": "popup_tokenTitle",
  "从 Siphon 设置 → 集成 复制": "popup_tokenPlaceholder",
  "保存": "popup_save",
  "推荐在 Siphon 中「安装原生网关」：令牌由本机 0600 文件自动传递，无需填写。仅当扩展走 HTTP 回退时，才需要把 Siphon 设置里的令牌粘贴到这里。出于安全考虑，/ping 不再下发令牌。": "popup_tokenHelp",
  "保存设置": "popup_saveConfig",
};

function localizeDocument() {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    const source = node.nodeValue.trim();
    const key = SOURCE_KEYS[source];
    if (!key) continue;
    const translated = t(key, source);
    if (translated !== source) node.nodeValue = node.nodeValue.replace(source, translated);
  }
  for (const el of document.querySelectorAll("[placeholder]")) {
    const source = el.getAttribute("placeholder").trim();
    const key = SOURCE_KEYS[source];
    if (key) el.setAttribute("placeholder", t(key, source));
  }
  for (const el of document.querySelectorAll("[title]")) {
    const source = el.getAttribute("title").trim();
    const key = SOURCE_KEYS[source];
    if (key) el.setAttribute("title", t(key, source));
  }
}

localizeDocument();

const statusEl = document.getElementById("status");
const captureAllEl = document.getElementById("captureAll");
const notifyOnCaptureEl = document.getElementById("notifyOnCapture");
const listEl = document.getElementById("list");
const sendAllBtn = document.getElementById("sendAll");
const refreshBtn = document.getElementById("refresh");
const clearBtn = document.getElementById("clear");
const resetStatsBtn = document.getElementById("resetStats");
const saveConfigBtn = document.getElementById("saveConfig");
const minFileSizeEl = document.getElementById("minFileSize");
const newExcludeHostEl = document.getElementById("newExcludeHost");
const addExcludeHostBtn = document.getElementById("addExcludeHost");
const excludeHostsListEl = document.getElementById("excludeHostsList");
const newExcludeExtEl = document.getElementById("newExcludeExt");
const addExcludeExtBtn = document.getElementById("addExcludeExt");
const excludeExtsListEl = document.getElementById("excludeExtsList");
const apiTokenEl = document.getElementById("apiToken");
const saveTokenBtn = document.getElementById("saveToken");
const tokenStatusEl = document.getElementById("tokenStatus");
const extensionIdEl = document.getElementById("extensionId");
const copyExtensionIdBtn = document.getElementById("copyExtensionId");
const diagTextEl = document.getElementById("diagText");

const statEls = {
  intercepted: document.getElementById("stat-intercepted"),
  skipped: document.getElementById("stat-skipped"),
  media: document.getElementById("stat-media"),
  errors: document.getElementById("stat-errors"),
};
const recentListEl = document.getElementById("recentList");
const recentSearchEl = document.getElementById("recentSearch");
const refreshRecentBtn = document.getElementById("refreshRecent");
const recentFiltersEl = document.getElementById("recentFilters");
const siteInfoEl = document.getElementById("siteInfo");
const toggleSiteCaptureBtn = document.getElementById("toggleSiteCapture");
const clearCompletedBtn = document.getElementById("clearCompleted");
const imageMinWidthEl = document.getElementById("imageMinWidth");
const imageMinHeightEl = document.getElementById("imageMinHeight");
const collectImagesBtn = document.getElementById("collectImages");
const imageListEl = document.getElementById("imageList");
const imageCountEl = document.getElementById("imageCount");
const sendImagesBtn = document.getElementById("sendImages");
const selectAllImagesBtn = document.getElementById("selectAllImages");
const transportInfoEl = document.getElementById("transportInfo");
const proxyInfoEl = document.getElementById("proxyInfo");
const refreshConnectionBtn = document.getElementById("refreshConnection");
const openAppSettingsBtn = document.getElementById("openAppSettings");

let currentTabId = -1;
let currentItems = [];
let excludeHosts = [];
let excludeExts = [];
let recentItems = [];
let recentFilter = "all";
let siteHost = "";
let pageImages = [];
let imagesLoaded = false;

// MARK: - Downloads tab (MDM popup contract)

async function loadRecent() {
  try {
    const res = await chrome.runtime.sendMessage({ type: "recent" });
    recentItems = res?.ok ? (res.recent || []) : [];
  } catch (_) {
    recentItems = [];
  }
  renderRecent();
}

const STATUS_LABEL = {
  queued: t("popup_statusQueued", "排队中"),
  downloading: t("popup_statusDownloading", "下载中"),
  stopped: t("popup_statusStopped", "已暂停"),
  complete: t("popup_statusComplete", "已完成"),
  error: t("popup_statusError", "失败"),
};

function renderRecent() {
  recentListEl.textContent = "";
  const query = (recentSearchEl.value || "").trim().toLowerCase();
  const items = recentItems.filter(item => {
    if (recentFilter === "downloading"
        && item.status !== "downloading" && item.status !== "queued") return false;
    if (recentFilter === "complete" && item.status !== "complete") return false;
    if (recentFilter === "error" && item.status !== "error") return false;
    if (!query) return true;
    return String(item.fileName || "").toLowerCase().includes(query)
      || String(item.url || "").toLowerCase().includes(query);
  });
  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = t("popup_recentEmpty", "最近没有匹配的下载。");
    recentListEl.appendChild(empty);
    return;
  }
  for (const item of items) {
    const row = document.createElement("div");
    row.className = "item";
    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = item.fileName || fileName(item.url);
    name.title = item.url || "";
    const host = document.createElement("span");
    host.className = "host";
    const pct = item.size > 0 ? Math.round((item.downloaded / item.size) * 100) : 0;
    const speed = item.status === "downloading" && item.speed > 0
      ? ` · ${fmtBytes(item.speed)}/s` : "";
    host.textContent = `${STATUS_LABEL[item.status] || item.status || ""} · ${pct}% · ${fmtBytes(item.downloaded || 0)}/${fmtBytes(item.size || 0)}${speed}`;
    meta.appendChild(name);
    meta.appendChild(host);

    const actions = document.createElement("div");
    actions.className = "actions";
    if (item.status === "downloading" || item.status === "queued") {
      addRecentAction(actions, t("popup_pause", "暂停"), "pause", item);
    } else if (item.status === "stopped" || item.status === "error") {
      addRecentAction(actions, t("popup_resume", "继续"), "resume", item);
    }
    addRecentAction(actions, t("popup_remove", "移除"), "remove", item);

    const copy = document.createElement("button");
    copy.className = "btn-secondary";
    copy.textContent = t("popup_copyLink", "复制链接");
    copy.addEventListener("click", () => {
      if (navigator.clipboard) navigator.clipboard.writeText(item.url || "");
    });

    row.appendChild(meta);
    row.appendChild(actions);
    row.appendChild(copy);
    recentListEl.appendChild(row);
  }
}

async function downloadAct(act, id) {
  try {
    const res = await chrome.runtime.sendMessage({ type: "downloadAct", act, id });
    if (!res || !res.ok) return false;
    if (res.act && res.act.done === false) return false;
    return true;
  } catch (_) {
    return false;
  }
}

function addRecentAction(parent, label, act, item) {
  const btn = document.createElement("button");
  btn.className = act === "remove" ? "btn-danger" : "btn-secondary";
  btn.textContent = label;
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "…";
    const ok = await downloadAct(act, item.id);
    if (ok) {
      await loadRecent();
    } else {
      btn.textContent = t("popup_failed", "失败");
      setTimeout(() => { btn.textContent = label; btn.disabled = false; }, 1200);
    }
  });
  parent.appendChild(btn);
}

recentFiltersEl.addEventListener("click", event => {
  const btn = event.target.closest("button[data-filter]");
  if (!btn) return;
  recentFilter = btn.dataset.filter;
  recentFiltersEl.querySelectorAll("button").forEach(b => b.classList.remove("active"));
  btn.classList.add("active");
  renderRecent();
});
recentSearchEl.addEventListener("input", renderRecent);
refreshRecentBtn.addEventListener("click", loadRecent);

clearCompletedBtn.addEventListener("click", async () => {
  const done = recentItems.filter(item => item.status === "complete");
  if (!done.length) return;
  clearCompletedBtn.disabled = true;
  clearCompletedBtn.textContent = t("popup_clearing", "清理中…");
  for (const item of done) await downloadAct("remove", item.id);
  await loadRecent();
  clearCompletedBtn.disabled = false;
  clearCompletedBtn.textContent = t("popup_clearCompleted", "清空已完成");
});

// MARK: - This page tab

async function loadSiteInfo() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    siteHost = tab?.url ? new URL(tab.url).host : "";
  } catch (_) { siteHost = ""; }
  siteInfoEl.textContent = siteHost
    ? tf("popup_currentSite", "当前站点：{host}", { host: siteHost })
    : t("popup_noSite", "当前页面没有可用的站点地址。");
  const excluded = excludeHosts.includes(siteHost);
  toggleSiteCaptureBtn.textContent = excluded
    ? t("popup_resumeSite", "恢复本站接管")
    : t("popup_siteDisable", "本站不再接管");
  toggleSiteCaptureBtn.disabled = !siteHost;
}

toggleSiteCaptureBtn.addEventListener("click", async () => {
  if (!siteHost) return;
  const enabled = excludeHosts.includes(siteHost);
  try {
    const res = await chrome.runtime.sendMessage({
      type: "setSiteCapture", host: siteHost, enabled,
    });
    if (res?.ok) {
      excludeHosts = res.excludeHosts || [];
      loadSiteInfo();
    }
  } catch (_) {}
});

// MARK: - images (link grabber)

function imageMatches(item) {
  const minW = parseInt(imageMinWidthEl.value, 10) || 0;
  const minH = parseInt(imageMinHeightEl.value, 10) || 0;
  return (item.width || 0) >= minW && (item.height || 0) >= minH;
}

function visibleImages() {
  return pageImages.filter(imageMatches);
}

async function loadImages() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  currentTabId = tab?.id ?? -1;
  try {
    const res = await chrome.runtime.sendMessage({ type: "images", tabId: currentTabId });
    if (res?.ok) {
      pageImages = (res.items || [])
        .map(item => ({ ...item, selected: false }))
        .sort((a, b) => (b.width * b.height) - (a.width * a.height));
      imagesLoaded = true;
    } else {
      pageImages = [];
    }
  } catch (_) {
    pageImages = [];
  }
  renderImages();
}

function renderImages() {
  imageListEl.textContent = "";
  const items = visibleImages();
  const allSelected = items.length > 0 && items.every(item => item.selected);
  const selectedCount = items.filter(item => item.selected).length;
  sendImagesBtn.disabled = selectedCount === 0;
  selectAllImagesBtn.textContent = allSelected
    ? t("popup_deselectAll", "取消全选")
    : t("popup_selectAll", "全选");
  selectAllImagesBtn.disabled = items.length === 0;
  imageCountEl.textContent = imagesLoaded
    ? tf("popup_imageCount", "共 {n} 张 · 已选 {m} 张", { n: items.length, m: selectedCount })
    : t("popup_imagesNotCollected", "尚未收集图片");
  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = imagesLoaded
      ? t("popup_imageNoneMatch", "没有符合尺寸的图片。")
      : t("popup_imageCollectHint", "点「收集图片」读取当前页面。");
    imageListEl.appendChild(empty);
    return;
  }
  items.forEach(item => {
    const row = document.createElement("div");
    row.className = "item";

    const check = document.createElement("input");
    check.type = "checkbox";
    check.checked = !!item.selected;
    check.addEventListener("change", () => {
      item.selected = check.checked;
      const visible = visibleImages();
      const selected = visible.filter(i => i.selected).length;
      sendImagesBtn.disabled = selected === 0;
      selectAllImagesBtn.textContent = visible.length > 0 && selected === visible.length
        ? t("popup_deselectAll", "取消全选") : t("popup_selectAll", "全选");
      imageCountEl.textContent = tf("popup_imageCount", "共 {n} 张 · 已选 {m} 张",
        { n: visible.length, m: selected });
    });

    const thumb = document.createElement("img");
    thumb.className = "thumb";
    thumb.loading = "lazy";
    thumb.referrerPolicy = "no-referrer";
    thumb.alt = "";
    thumb.src = item.url;

    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = fileName(item.url);
    name.title = item.url;
    const dims = document.createElement("span");
    dims.className = "host";
    dims.textContent = `${item.width || "?"}×${item.height || "?"} · ${hostName(item.url)}`;
    meta.appendChild(name);
    meta.appendChild(dims);

    const open = document.createElement("button");
    open.className = "btn-secondary";
    open.textContent = t("popup_open", "打开");
    open.addEventListener("click", () => {
      try { chrome.tabs.create({ url: item.url }); } catch (_) {}
    });

    row.appendChild(check);
    row.appendChild(thumb);
    row.appendChild(meta);
    row.appendChild(open);
    imageListEl.appendChild(row);
  });
}

collectImagesBtn.addEventListener("click", loadImages);
imageMinWidthEl.addEventListener("input", renderImages);
imageMinHeightEl.addEventListener("input", renderImages);

selectAllImagesBtn.addEventListener("click", () => {
  const items = visibleImages();
  const allSelected = items.length > 0 && items.every(item => item.selected);
  items.forEach(item => { item.selected = !allSelected; });
  renderImages();
});

sendImagesBtn.addEventListener("click", async () => {
  const urls = visibleImages().filter(item => item.selected).map(item => item.url);
  if (!urls.length) return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  sendImagesBtn.disabled = true;
  sendImagesBtn.textContent = t("popup_sending", "发送中…");
  try {
    const res = await chrome.runtime.sendMessage({
      type: "sendImages",
      urls,
      referrer: tab?.url || "",
      private: !!tab?.incognito,
    });
    sendImagesBtn.textContent = res?.ok
      ? tf("popup_sentCount", "已发送 {sent}/{count}", { sent: res.sent, count: res.count })
      : t("popup_sendFailed", "发送失败");
  } catch (_) {
    sendImagesBtn.textContent = t("popup_sendFailed", "发送失败");
  }
  setTimeout(() => {
    sendImagesBtn.textContent = t("popup_sendSelected", "发送选中");
    sendImagesBtn.disabled = !visibleImages().some(item => item.selected);
  }, 1600);
});

// MARK: - tabs

document.querySelectorAll(".tab-bar button").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-bar button").forEach(b => b.classList.remove("active"));
    document.querySelectorAll(".tab-content").forEach(c => c.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("tab-" + btn.dataset.tab).classList.add("active");
    if (btn.dataset.tab === "media" && !imagesLoaded) loadImages();
    if (btn.dataset.tab === "config") refreshConnectionState();
  });
});

// MARK: - helpers

function fileName(url) {
  try {
    const u = new URL(url);
    const last = u.pathname.split("/").filter(Boolean).pop() || t("popup_kindMedia", "媒体");
    return decodeURIComponent(last);
  } catch (_) {
    return url;
  }
}

function hostName(url) {
  try { return new URL(url).host; } catch (_) { return ""; }
}

function fmtBytes(n) {
  if (n < 1024) return n + " B";
  if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
  if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB";
  return (n / 1073741824).toFixed(2) + " GB";
}

// MARK: - config

async function loadConfig() {
  try {
    const res = await chrome.runtime.sendMessage({ type: "getConfig" });
    if (res?.ok && res.config) {
      captureAllEl.checked = res.config.captureAll ?? true;
      notifyOnCaptureEl.checked = res.config.notifyOnCapture ?? true;
      minFileSizeEl.value = ((res.config.minFileSize ?? 0) / 1048576).toFixed(1);
      excludeHosts = res.config.excludeHosts || [];
      excludeExts = res.config.excludeExts || [];
      renderExcludeLists();
    }
  } catch (_) {}
}

function renderExcludeLists() {
  excludeHostsListEl.textContent = "";
  if (!excludeHosts.length) {
    const empty = document.createElement("span");
    empty.className = "empty";
    empty.textContent = t("popup_noExcludedHosts", "无排除站点");
    excludeHostsListEl.appendChild(empty);
  } else {
    for (const host of excludeHosts) {
      const row = document.createElement("div");
      row.className = "exclude-item";
      const label = document.createElement("span");
      label.textContent = host;
      const btn = document.createElement("button");
      btn.textContent = t("popup_delete", "删除");
      btn.addEventListener("click", () => {
        excludeHosts = excludeHosts.filter(h => h !== host);
        renderExcludeLists();
      });
      row.appendChild(label);
      row.appendChild(btn);
      excludeHostsListEl.appendChild(row);
    }
  }

  excludeExtsListEl.textContent = "";
  if (!excludeExts.length) {
    const empty = document.createElement("span");
    empty.className = "empty";
    empty.textContent = t("popup_noExcludedExts", "无排除扩展名");
    excludeExtsListEl.appendChild(empty);
  } else {
    for (const ext of excludeExts) {
      const row = document.createElement("div");
      row.className = "exclude-item";
      const label = document.createElement("span");
      label.textContent = ext;
      const btn = document.createElement("button");
      btn.textContent = t("popup_delete", "删除");
      btn.addEventListener("click", () => {
        excludeExts = excludeExts.filter(e => e !== ext);
        renderExcludeLists();
      });
      row.appendChild(label);
      row.appendChild(btn);
      excludeExtsListEl.appendChild(row);
    }
  }
}

addExcludeHostBtn.addEventListener("click", () => {
  const val = newExcludeHostEl.value.trim();
  if (!val) return;
  if (!excludeHosts.includes(val)) {
    excludeHosts.push(val);
    renderExcludeLists();
  }
  newExcludeHostEl.value = "";
});

addExcludeExtBtn.addEventListener("click", () => {
  const val = newExcludeExtEl.value.trim().toLowerCase().replace(/^\./, "");
  if (!val) return;
  if (!excludeExts.includes(val)) {
    excludeExts.push(val);
    renderExcludeLists();
  }
  newExcludeExtEl.value = "";
});

saveConfigBtn.addEventListener("click", async () => {
  const mb = parseFloat(minFileSizeEl.value) || 0;
  const config = {
    captureAll: captureAllEl.checked,
    notifyOnCapture: notifyOnCaptureEl.checked,
    minFileSize: Math.round(mb * 1048576),
    excludeHosts,
    excludeExts,
  };
  try {
    await chrome.runtime.sendMessage({ type: "setConfig", config });
    saveConfigBtn.textContent = t("popup_saved", "已保存");
    setTimeout(() => { saveConfigBtn.textContent = t("popup_saveConfig", "保存设置"); }, 1200);
  } catch (_) {
    saveConfigBtn.textContent = t("popup_saveFailed", "保存失败");
    setTimeout(() => { saveConfigBtn.textContent = t("popup_saveConfig", "保存设置"); }, 1200);
  }
});

// MARK: - stats

async function loadStats() {
  try {
    const res = await chrome.runtime.sendMessage({ type: "getStats" });
    if (res?.ok && res.stats) {
      for (const [k, el] of Object.entries(statEls)) {
        el.textContent = res.stats[k] ?? 0;
      }
    }
  } catch (_) {}
}

resetStatsBtn.addEventListener("click", async () => {
  try {
    const res = await chrome.runtime.sendMessage({ type: "resetStats" });
    if (res?.ok && res.stats) {
      for (const [k, el] of Object.entries(statEls)) {
        el.textContent = res.stats[k] ?? 0;
      }
    }
  } catch (_) {}
});

// MARK: - media sniff

function mediaKind(item) {
  const url = String(item.url || "").toLowerCase();
  if (/\.m3u8(\?|#|$)/.test(url)) return "HLS";
  if (/\.mpd(\?|#|$)/.test(url)) return "DASH";
  const type = String(item.type || "").toLowerCase();
  if (type.startsWith("audio/")) return t("popup_kindAudio", "音频");
  if (type.startsWith("video/")) return t("popup_kindVideo", "视频");
  return t("popup_kindMedia", "媒体");
}

function render(items) {
  currentItems = items || [];
  listEl.textContent = "";
  if (!currentItems.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = t("popup_noMedia", "未嗅探到媒体链接。播放视频后再打开此弹窗。");
    listEl.appendChild(empty);
    sendAllBtn.disabled = true;
    return;
  }
  sendAllBtn.disabled = false;
  for (const item of currentItems) {
    const row = document.createElement("div");
    row.className = "item";

    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = fileName(item.url);
    name.title = item.url;
    const host = document.createElement("span");
    host.className = "host";
    host.textContent = `${mediaKind(item)} · ${hostName(item.url)}`;
    meta.appendChild(name);
    meta.appendChild(host);

    const btn = document.createElement("button");
    btn.textContent = t("popup_send", "发送");
    btn.addEventListener("click", () => sendOne(item.url, btn));

    row.appendChild(meta);
    row.appendChild(btn);
    listEl.appendChild(row);
  }
}

async function sendOne(url, btn) {
  btn.disabled = true;
  const original = btn.textContent;
  btn.textContent = t("popup_sending", "发送中…");
  try {
    const res = await chrome.runtime.sendMessage({ type: "send", url });
    btn.textContent = res?.ok ? t("popup_sent", "已发送") : t("popup_failed", "失败");
    if (!res?.ok) setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 1500);
  } catch (_) {
    btn.textContent = t("popup_failed", "失败");
    setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 1500);
  }
}

async function refreshList() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  currentTabId = tab?.id ?? -1;
  try {
    const res = await chrome.runtime.sendMessage({ type: "sniffed", tabId: currentTabId });
    render(res?.items ?? []);
  } catch (_) {
    render([]);
  }
}

sendAllBtn.addEventListener("click", async () => {
  sendAllBtn.disabled = true;
  const buttons = Array.from(listEl.querySelectorAll(".item button"));
  for (let i = 0; i < currentItems.length; i++) {
    const btn = buttons[i];
    if (btn) await sendOne(currentItems[i].url, btn);
  }
  sendAllBtn.disabled = false;
});

refreshBtn.addEventListener("click", refreshList);
clearBtn.addEventListener("click", async () => {
  try { await chrome.runtime.sendMessage({ type: "clearSniffed", tabId: currentTabId }); } catch (_) {}
  render([]);
});

// MARK: - status

chrome.runtime.sendMessage({ type: "ping" }, res => {
  statusEl.textContent = res?.ok
    ? t("popup_connected", "● 已连接 Siphon")
    : t("popup_disconnected", "○ Siphon 未运行");
  statusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
});

// MARK: - connection diagnostics

function describeTransport(res) {
  if (!res) return t("popup_transportNone", "未连接");
  if (res.nativeOk) return t("popup_transportNative", "原生网关");
  if (res.appReachable) return res.tokenConfigured
    ? t("popup_transportHttp", "HTTP 回退")
    : t("popup_transportHttpNoToken", "HTTP 回退（缺令牌）");
  return t("popup_transportNone", "未连接");
}

function refreshConnectionState() {
  chrome.runtime.sendMessage({ type: "diagnose" }, res => {
    if (!res?.ok) {
      diagTextEl.textContent = t("popup_diagFailed",
        "诊断失败：扩展后台未响应，请在扩展页重新加载本扩展。");
      transportInfoEl.textContent = t("popup_transportNone", "未连接");
      return;
    }
    extensionIdEl.textContent = res.extensionId || t("popup_unknown", "未知");
    transportInfoEl.textContent = describeTransport(res);
    const lines = [
      res.appReachable
        ? t("popup_diagAppOnline", "● Siphon 本地接口在线")
        : t("popup_diagAppOffline", "○ Siphon 本地接口不可达：请先启动 App"),
      res.nativeOk
        ? t("popup_diagNativeOk", "● 原生网关可用（推荐通道）")
        : t("popup_diagNativeMissing", "○ 原生网关不可用：清单未安装，或其中允许的扩展 ID 与上方不一致"),
      res.tokenConfigured
        ? t("popup_diagTokenOk", "● HTTP 回退令牌已配置")
        : t("popup_diagTokenMissing", "○ HTTP 回退令牌未配置：若原生网关不可用，请在下方粘贴令牌"),
    ];
    if (res.nativeError) {
      lines.push(tf("popup_diagErrorDetail", "错误详情：{error}", { error: res.nativeError }));
    }
    diagTextEl.textContent = lines.join("\n");
  });
  chrome.runtime.sendMessage({ type: "getProxy" }, res => {
    if (!res?.ok) { proxyInfoEl.textContent = t("popup_proxyUnreadable", "不可读"); return; }
    if (res.proxyPac) proxyInfoEl.textContent = t("popup_proxyPac", "PAC 脚本");
    else if (res.proxy) proxyInfoEl.textContent = res.proxy;
    else proxyInfoEl.textContent = t("popup_proxySystem", "跟随系统");
  });
}

refreshConnectionBtn.addEventListener("click", refreshConnectionState);
openAppSettingsBtn.addEventListener("click", () => {
  try { chrome.tabs.create({ url: "siphon://options" }); } catch (_) {}
});

copyExtensionIdBtn.addEventListener("click", async () => {
  const id = extensionIdEl.textContent || "";
  try {
    await navigator.clipboard.writeText(id);
  } catch (_) {
    const range = document.createRange();
    range.selectNodeContents(extensionIdEl);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    try { document.execCommand("copy"); } catch (_) {}
    sel.removeAllRanges();
  }
  copyExtensionIdBtn.textContent = t("popup_copied", "已复制");
  setTimeout(() => { copyExtensionIdBtn.textContent = t("popup_copyExtensionId", "复制扩展 ID"); }, 1500);
});

// MARK: - init

// The token is no longer discoverable over the loopback API. Load whatever the
// user previously pasted and let them replace it after a rotation in the app.
chrome.runtime.sendMessage({ type: "getToken" }, res => {
  if (res?.ok) apiTokenEl.value = res.token || "";
});

saveTokenBtn.addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "setToken", token: apiTokenEl.value }, res => {
    tokenStatusEl.textContent = res?.ok
      ? t("popup_tokenSaved", "已保存令牌")
      : t("popup_tokenSaveFailed", "保存失败，请重试");
    tokenStatusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
  });
});

(async () => {
  await loadConfig();
  await Promise.all([loadStats(), loadRecent(), refreshList(), loadSiteInfo()]);
  refreshConnectionState();
})();

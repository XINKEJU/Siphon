// popup.js — tabbed UI for Siphon v3 extension

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

let currentTabId = -1;
let currentItems = [];
let excludeHosts = [];
let excludeExts = [];

// MARK: - tabs

document.querySelectorAll(".tab-bar button").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-bar button").forEach(b => b.classList.remove("active"));
    document.querySelectorAll(".tab-content").forEach(c => c.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("tab-" + btn.dataset.tab).classList.add("active");
  });
});

// MARK: - helpers

function fileName(url) {
  try {
    const u = new URL(url);
    const last = u.pathname.split("/").filter(Boolean).pop() || "媒体";
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
    excludeHostsListEl.innerHTML = '<span class="empty">无排除站点</span>';
  } else {
    for (const host of excludeHosts) {
      const row = document.createElement("div");
      row.className = "exclude-item";
      const label = document.createElement("span");
      label.textContent = host;
      const btn = document.createElement("button");
      btn.textContent = "删除";
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
    excludeExtsListEl.innerHTML = '<span class="empty">无排除扩展名</span>';
  } else {
    for (const ext of excludeExts) {
      const row = document.createElement("div");
      row.className = "exclude-item";
      const label = document.createElement("span");
      label.textContent = ext;
      const btn = document.createElement("button");
      btn.textContent = "删除";
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
    saveConfigBtn.textContent = "已保存";
    setTimeout(() => { saveConfigBtn.textContent = "保存设置"; }, 1200);
  } catch (_) {
    saveConfigBtn.textContent = "保存失败";
    setTimeout(() => { saveConfigBtn.textContent = "保存设置"; }, 1200);
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

function render(items) {
  currentItems = items || [];
  listEl.textContent = "";
  if (!currentItems.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "未嗅探到媒体链接。播放视频后再打开此弹窗。";
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
    host.textContent = hostName(item.url);
    meta.appendChild(name);
    meta.appendChild(host);

    const btn = document.createElement("button");
    btn.textContent = "发送";
    btn.addEventListener("click", () => sendOne(item.url, btn));

    row.appendChild(meta);
    row.appendChild(btn);
    listEl.appendChild(row);
  }
}

async function sendOne(url, btn) {
  btn.disabled = true;
  const original = btn.textContent;
  btn.textContent = "发送中…";
  try {
    const res = await chrome.runtime.sendMessage({ type: "send", url });
    btn.textContent = res?.ok ? "已发送" : "失败";
    if (!res?.ok) setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 1500);
  } catch (_) {
    btn.textContent = "失败";
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
  statusEl.textContent = res?.ok ? "● 已连接 Siphon" : "○ Siphon 未运行";
  statusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
});

// MARK: - connection diagnostics

chrome.runtime.sendMessage({ type: "diagnose" }, res => {
  if (!res?.ok) {
    diagTextEl.textContent = "诊断失败：扩展后台未响应，请在扩展页重新加载本扩展。";
    return;
  }
  extensionIdEl.textContent = res.extensionId || "未知";
  const lines = [
    res.appReachable ? "● Siphon 本地接口在线" : "○ Siphon 本地接口不可达：请先启动 App",
    res.nativeOk
      ? "● 原生网关可用（推荐通道）"
      : "○ 原生网关不可用：清单未安装，或其中允许的扩展 ID 与上方不一致",
    res.tokenConfigured
      ? "● HTTP 回退令牌已配置"
      : "○ HTTP 回退令牌未配置：若原生网关不可用，请在下方粘贴令牌",
  ];
  if (res.nativeError) lines.push("错误详情：" + res.nativeError);
  diagTextEl.textContent = lines.join("\n");
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
  copyExtensionIdBtn.textContent = "已复制";
  setTimeout(() => { copyExtensionIdBtn.textContent = "复制扩展 ID"; }, 1500);
});

// MARK: - init

// The token is no longer discoverable over the loopback API. Load whatever the
// user previously pasted and let them replace it after a rotation in the app.
chrome.runtime.sendMessage({ type: "getToken" }, res => {
  if (res?.ok) apiTokenEl.value = res.token || "";
});

saveTokenBtn.addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "setToken", token: apiTokenEl.value }, res => {
    tokenStatusEl.textContent = res?.ok ? "已保存令牌" : "保存失败，请重试";
    tokenStatusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
  });
});

loadConfig();
loadStats();
refreshList();

const statusEl = document.getElementById("status");
const toggle = document.getElementById("captureAll");
const listEl = document.getElementById("list");
const sendAllBtn = document.getElementById("sendAll");
const refreshBtn = document.getElementById("refresh");
const clearBtn = document.getElementById("clear");

let currentTabId = -1;
let currentItems = [];

chrome.storage.local.get("captureAll").then(v => {
  toggle.checked = v.captureAll ?? false;
});

toggle.addEventListener("change", () => {
  chrome.storage.local.set({ captureAll: toggle.checked });
});

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
  const buttons = Array.from(listEl.querySelectorAll("button"));
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

chrome.runtime.sendMessage({ type: "ping" }, res => {
  statusEl.textContent = res?.ok ? "● 已连接 Siphon" : "○ Siphon 未运行";
  statusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
});

refreshList();

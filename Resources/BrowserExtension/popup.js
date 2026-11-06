const statusEl = document.getElementById("status");
const toggle = document.getElementById("captureAll");

chrome.storage.local.get("captureAll").then(v => {
  toggle.checked = v.captureAll ?? false;
});

toggle.addEventListener("change", () => {
  chrome.storage.local.set({ captureAll: toggle.checked });
});

chrome.runtime.sendMessage({ type: "ping" }, res => {
  statusEl.textContent = res?.ok ? "● 已连接 Siphon" : "○ Siphon 未运行";
  statusEl.style.color = res?.ok ? "#0f6e56" : "#a32d2d";
});

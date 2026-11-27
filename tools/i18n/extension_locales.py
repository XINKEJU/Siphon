#!/usr/bin/env python3
"""Generate the browser extension's Chrome WebExtension `_locales` bundle.

`MESSAGES` is the hand-written source of truth for every string the extension
can show: manifest name/description, popup, background notifications/menus and
the in-page floating button. English, Simplified Chinese and Traditional
Chinese are written by hand; every other Chrome locale falls back to English,
mirroring the App catalog's `status=machine` policy.

Run `python3 tools/i18n/extension_locales.py` to (re)write
`Resources/BrowserExtension/_locales/<code>/messages.json` idempotently.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Resources/BrowserExtension/_locales")

# 51 Chrome extension locale codes. en is the default_locale; zh_CN / zh_TW
# carry the hand-written Chinese catalogs, everything else falls back to en.
LOCALES = [
    "en", "zh_CN", "zh_TW",
    "ja", "ko", "de", "fr", "es", "es_419", "pt_BR", "pt_PT", "ru",
    "ar", "tr", "it", "nl", "pl", "sv", "da", "fi", "nb", "cs", "hu",
    "ro", "el", "he", "th", "vi", "id", "ms", "uk", "bg", "hr", "sr",
    "sk", "sl", "et", "lv", "lt", "fa", "hi", "bn", "ta", "te", "ml",
    "mr", "gu", "pa", "kn", "ur", "sw",
]

# Chrome locale code -> hand-written catalog. Missing means English fallback.
CATALOG = {"zh_CN": "zh-Hans", "zh_TW": "zh-Hant"}

MESSAGES = {
    # Manifest
    "extName": {
        "en": "Siphon Connector",
        "zh-Hans": "Siphon Connector",
        "zh-Hant": "Siphon Connector",
    },
    "extDescription": {
        "en": "Send browser downloads to the native Siphon macOS app. Supports Chrome, Edge, Brave, and Firefox.",
        "zh-Hans": "把浏览器下载交给本机 Siphon macOS App。支持 Chrome、Edge、Brave 和 Firefox。",
        "zh-Hant": "把瀏覽器下載交給本機 Siphon macOS App。支援 Chrome、Edge、Brave 和 Firefox。",
    },

    # popup.html static text
    "popup_status_checking": {
        "en": "Checking connection…",
        "zh-Hans": "检查连接…",
        "zh-Hant": "檢查連線…",
    },
    "popup_searchPlaceholder": {
        "en": "Search downloads",
        "zh-Hans": "搜索下载",
        "zh-Hant": "搜尋下載",
    },
    "popup_refresh": {
        "en": "Refresh",
        "zh-Hans": "刷新",
        "zh-Hant": "重新整理",
    },
    "popup_clearCompleted": {
        "en": "Clear completed",
        "zh-Hans": "清空已完成",
        "zh-Hant": "清除已完成",
    },
    "popup_statsTitle": {
        "en": "This session",
        "zh-Hans": "本次统计",
        "zh-Hant": "本次統計",
    },
    "popup_statIntercepted": {
        "en": "Captured",
        "zh-Hans": "已拦截",
        "zh-Hant": "已攔截",
    },
    "popup_statSkipped": {
        "en": "Skipped",
        "zh-Hans": "已跳过",
        "zh-Hant": "已略過",
    },
    "popup_statMedia": {
        "en": "Media found",
        "zh-Hans": "嗅探媒体",
        "zh-Hant": "嗅探媒體",
    },
    "popup_statErrors": {
        "en": "Errors",
        "zh-Hans": "错误",
        "zh-Hant": "錯誤",
    },
    "popup_resetStats": {
        "en": "Reset stats",
        "zh-Hans": "重置统计",
        "zh-Hant": "重設統計",
    },
    "popup_mediaSectionTitle": {
        "en": "Media on this page",
        "zh-Hans": "本页媒体",
        "zh-Hant": "本頁媒體",
    },
    "popup_siteDisable": {
        "en": "Stop capturing this site",
        "zh-Hans": "本站不再接管",
        "zh-Hant": "本站不再接管",
    },
    "popup_sniffedTitle": {
        "en": "Detected media",
        "zh-Hans": "嗅探到的媒体",
        "zh-Hant": "嗅探到的媒體",
    },
    "popup_sendAll": {
        "en": "Send all",
        "zh-Hans": "发送全部",
        "zh-Hant": "傳送全部",
    },
    "popup_clear": {
        "en": "Clear",
        "zh-Hans": "清空",
        "zh-Hant": "清除",
    },
    "popup_mediaHelp": {
        "en": "You can also right-click a link and choose “Download with Siphon”. DRM-protected videos cannot be downloaded; the floating button marks them.",
        "zh-Hans": "也可右键点击链接，选择「用 Siphon 下载」。受 DRM 保护的视频无法下载，浮钮会直接标注。",
        "zh-Hant": "也可右鍵點擊連結，選擇「用 Siphon 下載」。受 DRM 保護的影片無法下載，浮鈕會直接標註。",
    },
    "popup_imagesTitle": {
        "en": "Images on this page",
        "zh-Hans": "本页图片",
        "zh-Hant": "本頁圖片",
    },
    "popup_imageMinWidth": {
        "en": "Min width px",
        "zh-Hans": "最小宽度 px",
        "zh-Hant": "最小寬度 px",
    },
    "popup_imageMinHeight": {
        "en": "Min height px",
        "zh-Hans": "最小高度 px",
        "zh-Hant": "最小高度 px",
    },
    "popup_collectImages": {
        "en": "Collect images",
        "zh-Hans": "收集图片",
        "zh-Hant": "收集圖片",
    },
    "popup_imagesNotCollected": {
        "en": "No images collected yet",
        "zh-Hans": "尚未收集图片",
        "zh-Hant": "尚未收集圖片",
    },
    "popup_sendSelected": {
        "en": "Send selected",
        "zh-Hans": "发送选中",
        "zh-Hant": "傳送所選",
    },
    "popup_selectAll": {
        "en": "Select all",
        "zh-Hans": "全选",
        "zh-Hant": "全選",
    },
    "popup_imagesHelp": {
        "en": "Only http(s) images are collected; use width/height to filter out small icons.",
        "zh-Hans": "只收集 http(s) 图片；小图标可用宽高过滤掉。",
        "zh-Hant": "只收集 http(s) 圖片；小圖示可用寬高過濾掉。",
    },
    "popup_rulesTitle": {
        "en": "Capture rules",
        "zh-Hans": "接管规则",
        "zh-Hant": "接管規則",
    },
    "popup_captureAll": {
        "en": "Capture all browser downloads",
        "zh-Hans": "接管浏览器全部下载",
        "zh-Hant": "接管瀏覽器全部下載",
    },
    "popup_notifyOnCapture": {
        "en": "Show a notification on capture",
        "zh-Hans": "拦截时显示通知",
        "zh-Hant": "攔截時顯示通知",
    },
    "popup_rulesHelp": {
        "en": "Siphon's rules (file types, sites, minimum size, and more) take priority; these switches are the local fallback. The browser download is cancelled only after Siphon accepts the task; on failure the browser download continues and a notice is shown.",
        "zh-Hans": "扩展优先执行 Siphon 下发的接管规则（文件类型、站点、最小体积等）；这里的开关是本地兜底。只有 Siphon 接受任务后，扩展才会取消浏览器下载；失败时浏览器下载继续并弹出提示。",
        "zh-Hant": "擴充功能優先執行 Siphon 下發的接管規則（檔案類型、站點、最小體積等）；這裡的開關是本機後備。只有 Siphon 接受任務後，擴充功能才會取消瀏覽器下載；失敗時瀏覽器下載繼續並彈出提示。",
    },
    "popup_connectionTitle": {
        "en": "Local connection",
        "zh-Hans": "本机连接",
        "zh-Hant": "本機連線",
    },
    "popup_sendToLocal": {
        "en": "Send to this Mac",
        "zh-Hans": "发送到本机",
        "zh-Hant": "傳送到本機",
    },
    "popup_checking": {
        "en": "Checking…",
        "zh-Hans": "检查中…",
        "zh-Hant": "檢查中…",
    },
    "popup_browserProxy": {
        "en": "Browser proxy",
        "zh-Hans": "浏览器代理",
        "zh-Hant": "瀏覽器代理",
    },
    "popup_reading": {
        "en": "Reading…",
        "zh-Hans": "读取中…",
        "zh-Hant": "讀取中…",
    },
    "popup_refreshStatus": {
        "en": "Refresh status",
        "zh-Hans": "刷新状态",
        "zh-Hant": "重新整理狀態",
    },
    "popup_openAppSettings": {
        "en": "Open Siphon settings",
        "zh-Hans": "打开 Siphon 设置",
        "zh-Hant": "開啟 Siphon 設定",
    },
    "popup_diagnosticsTitle": {
        "en": "Connection diagnostics",
        "zh-Hans": "连接诊断",
        "zh-Hant": "連線診斷",
    },
    "popup_copyExtensionId": {
        "en": "Copy extension ID",
        "zh-Hans": "复制扩展 ID",
        "zh-Hant": "複製擴充功能 ID",
    },
    "popup_diagnosticsHelp": {
        "en": "Paste the extension ID into Siphon Settings → Integration → “Extension ID”, click “Install Native Gateway”, then quit and restart the browser completely (browsers read the gateway manifest only at startup).",
        "zh-Hans": "把扩展 ID 粘贴到 Siphon 设置 → 集成 →「扩展 ID」，点「安装原生网关」，然后完全退出并重启浏览器（浏览器只在启动时读取网关清单）。",
        "zh-Hant": "把擴充功能 ID 貼到 Siphon 設定 → 整合 →「擴充功能 ID」，點「安裝原生閘道」，然後完全退出並重新啟動瀏覽器（瀏覽器只在啟動時讀取閘道清單）。",
    },
    "popup_sizeFilterTitle": {
        "en": "File size filter",
        "zh-Hans": "文件大小过滤",
        "zh-Hant": "檔案大小過濾",
    },
    "popup_minFileSize": {
        "en": "Minimum file size (MB)",
        "zh-Hans": "最小文件大小（MB）",
        "zh-Hant": "最小檔案大小（MB）",
    },
    "popup_sizeFilterHelp": {
        "en": "0 means no limit. Files smaller than this are not captured and are downloaded by the browser.",
        "zh-Hans": "0 表示不限制。小于此大小的文件不拦截，由浏览器直接下载。",
        "zh-Hant": "0 表示不限制。小於此大小的檔案不攔截，由瀏覽器直接下載。",
    },
    "popup_excludeHostsTitle": {
        "en": "Excluded sites",
        "zh-Hans": "排除站点",
        "zh-Hant": "排除站點",
    },
    "popup_excludeHostPlaceholder": {
        "en": "e.g. youtube.com",
        "zh-Hans": "例如：youtube.com",
        "zh-Hant": "例如：youtube.com",
    },
    "popup_add": {
        "en": "Add",
        "zh-Hans": "添加",
        "zh-Hant": "新增",
    },
    "popup_excludeHostsHelp": {
        "en": "Downloads from excluded sites are handled by the browser.",
        "zh-Hans": "排除站点上的下载将由浏览器处理。",
        "zh-Hant": "排除站點上的下載將由瀏覽器處理。",
    },
    "popup_excludeExtsTitle": {
        "en": "Excluded extensions",
        "zh-Hans": "排除扩展名",
        "zh-Hant": "排除副檔名",
    },
    "popup_excludeExtPlaceholder": {
        "en": "e.g. html",
        "zh-Hans": "例如：html",
        "zh-Hant": "例如：html",
    },
    "popup_tokenTitle": {
        "en": "Local API token (HTTP fallback only)",
        "zh-Hans": "本地接口令牌（仅 HTTP 回退需要）",
        "zh-Hant": "本機介面權杖（僅 HTTP 回退需要）",
    },
    "popup_tokenPlaceholder": {
        "en": "Copy from Siphon Settings → Integration",
        "zh-Hans": "从 Siphon 设置 → 集成 复制",
        "zh-Hant": "從 Siphon 設定 → 整合 複製",
    },
    "popup_save": {
        "en": "Save",
        "zh-Hans": "保存",
        "zh-Hant": "儲存",
    },
    "popup_tokenHelp": {
        "en": "Recommended: use “Install Native Gateway” in Siphon. The token is passed automatically from a local 0600 file, so nothing needs to be entered. Only when the extension uses the HTTP fallback do you paste the token from Siphon Settings here. For security, /ping no longer returns the token.",
        "zh-Hans": "推荐在 Siphon 中「安装原生网关」：令牌由本机 0600 文件自动传递，无需填写。仅当扩展走 HTTP 回退时，才需要把 Siphon 设置里的令牌粘贴到这里。出于安全考虑，/ping 不再下发令牌。",
        "zh-Hant": "推薦在 Siphon 中「安裝原生閘道」：權杖由本機 0600 檔案自動傳遞，無需填寫。僅當擴充功能走 HTTP 回退時，才需要把 Siphon 設定裡的權杖貼到這裡。出於安全考量，/ping 不再下發權杖。",
    },
    "popup_saveConfig": {
        "en": "Save settings",
        "zh-Hans": "保存设置",
        "zh-Hant": "儲存設定",
    },

    # popup.js dynamic text
    "popup_statusQueued": {
        "en": "Queued",
        "zh-Hans": "排队中",
        "zh-Hant": "排隊中",
    },
    "popup_statusDownloading": {
        "en": "Downloading",
        "zh-Hans": "下载中",
        "zh-Hant": "下載中",
    },
    "popup_statusStopped": {
        "en": "Paused",
        "zh-Hans": "已暂停",
        "zh-Hant": "已暫停",
    },
    "popup_statusComplete": {
        "en": "Completed",
        "zh-Hans": "已完成",
        "zh-Hant": "已完成",
    },
    "popup_statusError": {
        "en": "Failed",
        "zh-Hans": "失败",
        "zh-Hant": "失敗",
    },
    "popup_recentEmpty": {
        "en": "No matching recent downloads.",
        "zh-Hans": "最近没有匹配的下载。",
        "zh-Hant": "最近沒有符合的下載。",
    },
    "popup_pause": {
        "en": "Pause",
        "zh-Hans": "暂停",
        "zh-Hant": "暫停",
    },
    "popup_resume": {
        "en": "Resume",
        "zh-Hans": "继续",
        "zh-Hant": "繼續",
    },
    "popup_remove": {
        "en": "Remove",
        "zh-Hans": "移除",
        "zh-Hant": "移除",
    },
    "popup_copyLink": {
        "en": "Copy link",
        "zh-Hans": "复制链接",
        "zh-Hant": "複製連結",
    },
    "popup_failed": {
        "en": "Failed",
        "zh-Hans": "失败",
        "zh-Hant": "失敗",
    },
    "popup_clearing": {
        "en": "Clearing…",
        "zh-Hans": "清理中…",
        "zh-Hant": "清理中…",
    },
    "popup_currentSite": {
        "en": "Current site: {host}",
        "zh-Hans": "当前站点：{host}",
        "zh-Hant": "目前站點：{host}",
    },
    "popup_noSite": {
        "en": "No site address is available for this page.",
        "zh-Hans": "当前页面没有可用的站点地址。",
        "zh-Hant": "目前頁面沒有可用的站點位址。",
    },
    "popup_resumeSite": {
        "en": "Resume capture for this site",
        "zh-Hans": "恢复本站接管",
        "zh-Hant": "恢復本站接管",
    },
    "popup_deselectAll": {
        "en": "Deselect all",
        "zh-Hans": "取消全选",
        "zh-Hant": "取消全選",
    },
    "popup_imageCount": {
        "en": "{n} images · {m} selected",
        "zh-Hans": "共 {n} 张 · 已选 {m} 张",
        "zh-Hant": "共 {n} 張 · 已選 {m} 張",
    },
    "popup_imageNoneMatch": {
        "en": "No images match the size filter.",
        "zh-Hans": "没有符合尺寸的图片。",
        "zh-Hant": "沒有符合尺寸的圖片。",
    },
    "popup_imageCollectHint": {
        "en": "Click “Collect images” to read this page.",
        "zh-Hans": "点「收集图片」读取当前页面。",
        "zh-Hant": "點「收集圖片」讀取目前頁面。",
    },
    "popup_open": {
        "en": "Open",
        "zh-Hans": "打开",
        "zh-Hant": "開啟",
    },
    "popup_sending": {
        "en": "Sending…",
        "zh-Hans": "发送中…",
        "zh-Hant": "傳送中…",
    },
    "popup_sentCount": {
        "en": "Sent {sent}/{count}",
        "zh-Hans": "已发送 {sent}/{count}",
        "zh-Hant": "已傳送 {sent}/{count}",
    },
    "popup_sendFailed": {
        "en": "Send failed",
        "zh-Hans": "发送失败",
        "zh-Hant": "傳送失敗",
    },
    "popup_noMedia": {
        "en": "No media links detected. Play a video, then reopen this popup.",
        "zh-Hans": "未嗅探到媒体链接。播放视频后再打开此弹窗。",
        "zh-Hant": "未嗅探到媒體連結。播放影片後再開啟此彈窗。",
    },
    "popup_send": {
        "en": "Send",
        "zh-Hans": "发送",
        "zh-Hant": "傳送",
    },
    "popup_sent": {
        "en": "Sent",
        "zh-Hans": "已发送",
        "zh-Hant": "已傳送",
    },
    "popup_connected": {
        "en": "● Connected to Siphon",
        "zh-Hans": "● 已连接 Siphon",
        "zh-Hant": "● 已連線 Siphon",
    },
    "popup_disconnected": {
        "en": "○ Siphon is not running",
        "zh-Hans": "○ Siphon 未运行",
        "zh-Hant": "○ Siphon 未執行",
    },
    "popup_delete": {
        "en": "Delete",
        "zh-Hans": "删除",
        "zh-Hant": "刪除",
    },
    "popup_noExcludedHosts": {
        "en": "No excluded sites",
        "zh-Hans": "无排除站点",
        "zh-Hant": "無排除站點",
    },
    "popup_noExcludedExts": {
        "en": "No excluded extensions",
        "zh-Hans": "无排除扩展名",
        "zh-Hant": "無排除副檔名",
    },
    "popup_saved": {
        "en": "Saved",
        "zh-Hans": "已保存",
        "zh-Hant": "已儲存",
    },
    "popup_saveFailed": {
        "en": "Save failed",
        "zh-Hans": "保存失败",
        "zh-Hant": "儲存失敗",
    },
    "popup_transportNone": {
        "en": "Not connected",
        "zh-Hans": "未连接",
        "zh-Hant": "未連線",
    },
    "popup_transportNative": {
        "en": "Native gateway",
        "zh-Hans": "原生网关",
        "zh-Hant": "原生閘道",
    },
    "popup_transportHttp": {
        "en": "HTTP fallback",
        "zh-Hans": "HTTP 回退",
        "zh-Hant": "HTTP 回退",
    },
    "popup_transportHttpNoToken": {
        "en": "HTTP fallback (no token)",
        "zh-Hans": "HTTP 回退（缺令牌）",
        "zh-Hant": "HTTP 回退（缺權杖）",
    },
    "popup_diagFailed": {
        "en": "Diagnostics failed: the extension background did not respond. Reload the extension.",
        "zh-Hans": "诊断失败：扩展后台未响应，请在扩展页重新加载本扩展。",
        "zh-Hant": "診斷失敗：擴充功能背景未回應，請在擴充功能頁重新載入本擴充功能。",
    },
    "popup_unknown": {
        "en": "Unknown",
        "zh-Hans": "未知",
        "zh-Hant": "未知",
    },
    "popup_diagAppOnline": {
        "en": "● Siphon local API is online",
        "zh-Hans": "● Siphon 本地接口在线",
        "zh-Hant": "● Siphon 本機介面在線",
    },
    "popup_diagAppOffline": {
        "en": "○ Siphon local API unreachable: start the app first",
        "zh-Hans": "○ Siphon 本地接口不可达：请先启动 App",
        "zh-Hant": "○ Siphon 本機介面不可達：請先啟動 App",
    },
    "popup_diagNativeOk": {
        "en": "● Native gateway available (recommended)",
        "zh-Hans": "● 原生网关可用（推荐通道）",
        "zh-Hant": "● 原生閘道可用（推薦通道）",
    },
    "popup_diagNativeMissing": {
        "en": "○ Native gateway unavailable: the manifest is not installed, or its allowed extension ID differs from the one above",
        "zh-Hans": "○ 原生网关不可用：清单未安装，或其中允许的扩展 ID 与上方不一致",
        "zh-Hant": "○ 原生閘道不可用：清單未安裝，或其中允許的擴充功能 ID 與上方不一致",
    },
    "popup_diagTokenOk": {
        "en": "● HTTP fallback token configured",
        "zh-Hans": "● HTTP 回退令牌已配置",
        "zh-Hant": "● HTTP 回退權杖已設定",
    },
    "popup_diagTokenMissing": {
        "en": "○ HTTP fallback token not configured: if the native gateway is unavailable, paste the token below",
        "zh-Hans": "○ HTTP 回退令牌未配置：若原生网关不可用，请在下方粘贴令牌",
        "zh-Hant": "○ HTTP 回退權杖未設定：若原生閘道不可用，請在下方貼上權杖",
    },
    "popup_diagErrorDetail": {
        "en": "Error details: {error}",
        "zh-Hans": "错误详情：{error}",
        "zh-Hant": "錯誤詳情：{error}",
    },
    "popup_proxyUnreadable": {
        "en": "Unreadable",
        "zh-Hans": "不可读",
        "zh-Hant": "無法讀取",
    },
    "popup_proxyPac": {
        "en": "PAC script",
        "zh-Hans": "PAC 脚本",
        "zh-Hant": "PAC 指令碼",
    },
    "popup_proxySystem": {
        "en": "Follow system",
        "zh-Hans": "跟随系统",
        "zh-Hant": "跟隨系統",
    },
    "popup_copied": {
        "en": "Copied",
        "zh-Hans": "已复制",
        "zh-Hant": "已複製",
    },
    "popup_tokenSaved": {
        "en": "Token saved",
        "zh-Hans": "已保存令牌",
        "zh-Hant": "已儲存權杖",
    },
    "popup_tokenSaveFailed": {
        "en": "Save failed, try again",
        "zh-Hans": "保存失败，请重试",
        "zh-Hant": "儲存失敗，請重試",
    },
    "popup_kindAudio": {
        "en": "Audio",
        "zh-Hans": "音频",
        "zh-Hant": "音訊",
    },
    "popup_kindVideo": {
        "en": "Video",
        "zh-Hans": "视频",
        "zh-Hant": "影片",
    },
    "popup_kindMedia": {
        "en": "Media",
        "zh-Hans": "媒体",
        "zh-Hant": "媒體",
    },

    # background.js
    "bg_ctxLink": {
        "en": "Download link with Siphon",
        "zh-Hans": "用 Siphon 下载链接",
        "zh-Hant": "用 Siphon 下載連結",
    },
    "bg_ctxImage": {
        "en": "Download image with Siphon",
        "zh-Hans": "用 Siphon 下载图片",
        "zh-Hant": "用 Siphon 下載圖片",
    },
    "bg_ctxMedia": {
        "en": "Download media with Siphon",
        "zh-Hans": "用 Siphon 下载媒体",
        "zh-Hant": "用 Siphon 下載媒體",
    },
    "bg_ctxSelection": {
        "en": "Download selected links with Siphon",
        "zh-Hans": "用 Siphon 下载选中的链接",
        "zh-Hant": "用 Siphon 下載所選連結",
    },
    "bg_ctxPage": {
        "en": "Download this page with Siphon",
        "zh-Hans": "用 Siphon 下载本页",
        "zh-Hant": "用 Siphon 下載本頁",
    },
    "bg_ctxAllLinks": {
        "en": "Download all links on this page with Siphon",
        "zh-Hans": "用 Siphon 下载本页全部链接",
        "zh-Hant": "用 Siphon 下載本頁全部連結",
    },
    "bg_ctxAllImages": {
        "en": "Download all images on this page with Siphon",
        "zh-Hans": "用 Siphon 下载本页全部图片",
        "zh-Hant": "用 Siphon 下載本頁全部圖片",
    },
    "bg_ctxBrowser": {
        "en": "Download with browser (do not capture)",
        "zh-Hans": "用浏览器下载（不接管）",
        "zh-Hant": "用瀏覽器下載（不接管）",
    },
    "bg_notifyCapturedTitle": {
        "en": "Siphon captured the download",
        "zh-Hans": "Siphon 已接管下载",
        "zh-Hant": "Siphon 已接管下載",
    },
    "bg_notifyFailedTitle": {
        "en": "Siphon capture failed: {name}",
        "zh-Hans": "Siphon 接管失败：{name}",
        "zh-Hant": "Siphon 接管失敗：{name}",
    },
    "bg_errNoLinks": {
        "en": "No downloadable links",
        "zh-Hans": "没有可下载的链接",
        "zh-Hant": "沒有可下載的連結",
    },
    "bg_sentLinks": {
        "en": "Sent {sent}/{count} links",
        "zh-Hans": "已发送 {sent}/{count} 个链接",
        "zh-Hant": "已傳送 {sent}/{count} 個連結",
    },
    "bg_sentImages": {
        "en": "Sent {sent}/{count} images",
        "zh-Hans": "已发送 {sent}/{count} 张图片",
        "zh-Hant": "已傳送 {sent}/{count} 張圖片",
    },
    "bg_errNoImages": {
        "en": "No images match the filter",
        "zh-Hans": "没有符合条件的图片",
        "zh-Hant": "沒有符合條件的圖片",
    },
    "bg_labelPageImages": {
        "en": "Images on this page",
        "zh-Hans": "本页图片",
        "zh-Hant": "本頁圖片",
    },
    "bg_labelPageLinks": {
        "en": "Links on this page",
        "zh-Hans": "本页链接",
        "zh-Hant": "本頁連結",
    },
    "bg_labelSelectedLinks": {
        "en": "Selected links",
        "zh-Hans": "选中的链接",
        "zh-Hant": "所選連結",
    },
    "bg_errReadImages": {
        "en": "Failed to read images on this page",
        "zh-Hans": "读取本页图片失败",
        "zh-Hant": "讀取本頁圖片失敗",
    },
    "bg_errReadLinks": {
        "en": "Failed to read links on this page",
        "zh-Hans": "读取本页链接失败",
        "zh-Hant": "讀取本頁連結失敗",
    },
    "bg_errTokenInvalid": {
        "en": "Invalid token. Paste the local API token again in the extension Settings.",
        "zh-Hans": "令牌无效，请在扩展「设置」里重新粘贴本地接口令牌",
        "zh-Hant": "權杖無效，請在擴充功能「設定」裡重新貼上本機介面權杖",
    },
    "bg_notifyFailedNative": {
        "en": "The native gateway is unavailable ({error}). In Siphon Settings → Integration, enter this extension's ID and click “Install Native Gateway”, then quit and restart the browser; or paste a token in the extension Settings to use the HTTP fallback.",
        "zh-Hans": "原生网关不可用（{error}）。请在 Siphon 设置 → 集成 填入本扩展 ID 并点「安装原生网关」，然后完全退出并重启浏览器；或在扩展「设置」里粘贴令牌走 HTTP 回退。",
        "zh-Hant": "原生閘道不可用（{error}）。請在 Siphon 設定 → 整合 填入本擴充功能 ID 並點「安裝原生閘道」，然後完全退出並重新啟動瀏覽器；或在擴充功能「設定」裡貼上權杖走 HTTP 回退。",
    },
    "bg_notifyFailedDefault": {
        "en": "Siphon is not running or the local API is unreachable",
        "zh-Hans": "Siphon 未运行或本地接口不可达",
        "zh-Hant": "Siphon 未執行或本機介面不可達",
    },
    "bg_errNoMedia": {
        "en": "No media stream detected",
        "zh-Hans": "未嗅探到媒体流",
        "zh-Hant": "未嗅探到媒體串流",
    },
    "bg_errTokenRotated": {
        "en": "Invalid or rotated token. Copy a new one from Siphon Settings → Integration and paste it again.",
        "zh-Hans": "令牌无效或已轮换，请在 Siphon 设置 → 集成 复制后重新粘贴",
        "zh-Hant": "權杖無效或已輪換，請在 Siphon 設定 → 整合 複製後重新貼上",
    },
    "bg_errTokenMissing": {
        "en": "Missing token. Paste Siphon's local API token in the extension Settings.",
        "zh-Hans": "缺少令牌，请在扩展「设置」中粘贴 Siphon 的本地接口令牌",
        "zh-Hant": "缺少權杖，請在擴充功能「設定」中貼上 Siphon 的本機介面權杖",
    },
    "bg_errUnsupported": {
        "en": "Unsupported address",
        "zh-Hans": "不支持的地址",
        "zh-Hant": "不支援的位址",
    },
    "bg_errNativeBackoff": {
        "en": "The native gateway is temporarily unavailable (backing off)",
        "zh-Hans": "原生网关暂不可用（已退避）",
        "zh-Hant": "原生閘道暫不可用（已退避）",
    },
    "bg_errNativeTimeout": {
        "en": "The native gateway timed out",
        "zh-Hans": "原生网关响应超时",
        "zh-Hant": "原生閘道回應逾時",
    },
    "bg_errNativeMissing": {
        "en": "The native gateway is not installed or the extension ID is not allow-listed",
        "zh-Hans": "原生网关未安装或扩展 ID 不在白名单",
        "zh-Hant": "原生閘道未安裝或擴充功能 ID 不在白名單",
    },

    # page.js
    "page_toastSending": {
        "en": "Sending to Siphon…",
        "zh-Hans": "正在发送到 Siphon…",
        "zh-Hant": "正在傳送到 Siphon…",
    },
    "page_toastSent": {
        "en": "Sent to Siphon",
        "zh-Hans": "已发送到 Siphon",
        "zh-Hant": "已傳送到 Siphon",
    },
    "page_toastNoResponse": {
        "en": "Siphon did not respond; handed off to the browser",
        "zh-Hans": "Siphon 未响应，已交给浏览器",
        "zh-Hant": "Siphon 未回應，已交給瀏覽器",
    },
    "page_btnIdle": {
        "en": "Send to Siphon",
        "zh-Hans": "发送到 Siphon",
        "zh-Hant": "傳送到 Siphon",
    },
    "page_btnTitle": {
        "en": "Send this video's media stream to Siphon",
        "zh-Hans": "把此视频的媒体流发送到 Siphon",
        "zh-Hant": "把此影片的媒體串流傳送到 Siphon",
    },
    "page_btnSending": {
        "en": "Sending…",
        "zh-Hans": "发送中…",
        "zh-Hant": "傳送中…",
    },
    "page_btnSent": {
        "en": "Sent",
        "zh-Hans": "已发送",
        "zh-Hant": "已傳送",
    },
    "page_btnNoMedia": {
        "en": "No media found",
        "zh-Hans": "未找到媒体",
        "zh-Hant": "未找到媒體",
    },
    "page_btnFailed": {
        "en": "Send failed",
        "zh-Hans": "发送失败",
        "zh-Hant": "傳送失敗",
    },
    "page_btnDrm": {
        "en": "DRM protected",
        "zh-Hans": "受 DRM 保护",
        "zh-Hant": "受 DRM 保護",
    },
    "page_btnDrmTitle": {
        "en": "DRM-protected videos cannot be downloaded",
        "zh-Hans": "受 DRM 保护的视频无法下载",
        "zh-Hant": "受 DRM 保護的影片無法下載",
    },
}

FALLBACK = "en"


def _catalog_for(code):
    return CATALOG.get(code, FALLBACK)


def _message_for(key, code):
    entry = MESSAGES[key]
    return entry.get(_catalog_for(code), entry[FALLBACK])


def write_locale(code):
    data = {key: {"message": _message_for(key, code)} for key in MESSAGES}
    directory = os.path.join(OUT, code)
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "messages.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    for code in LOCALES:
        write_locale(code)
    print(f"generated {len(LOCALES)} extension locales x {len(MESSAGES)} messages")


if __name__ == "__main__":
    main()
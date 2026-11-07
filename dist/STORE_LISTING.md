# Siphon Connector — 商店提交材料

## 扩展名称
**中文：** Siphon Connector — 全能下载接管
**英文：** Siphon Connector — Universal Download Manager

## 简短描述（商店副标题）
**中文：** 一键接管浏览器下载，发送至 Siphon 桌面端加速
**英文：** Intercept browser downloads and send to Siphon desktop for acceleration

## 详细描述

### 中文
Siphon Connector 是 Siphon 下载管理器的浏览器扩展，实现网页下载无缝接管。

**核心功能：**
- 🚀 **全量下载拦截** — 自动捕获浏览器所有下载请求，发送至 Siphon 桌面端处理
- 🎬 **媒体嗅探** — 自动检测页面中的视频/音频链接（m3u8、mpd、mp4、mp3 等）
- ⚡ **多线程加速** — 利用 Siphon 的多连接分段下载技术，速度提升 3-5 倍
- 📋 **剪贴板监听** — 复制下载链接后自动提示是否添加到 Siphon
- 🎯 **智能过滤** — 可配置最小文件大小、排除站点、排除扩展名
- 🔔 **桌面通知** — 拦截成功时弹出通知，一键查看下载进度

**支持的浏览器：**
- Google Chrome / Chromium
- Microsoft Edge
- Brave
- Mozilla Firefox

**使用方式：**
1. 安装 Siphon 桌面端（https://github.com/XINKEJU/Siphon）
2. 安装本扩展
3. 扩展会自动连接 Siphon，无需额外配置
4. 在浏览器中点击下载链接，Siphon 自动接管

**隐私说明：**
- 本扩展仅在本地与 Siphon 桌面端通信，不上传任何数据
- 不收集浏览历史、下载记录或个人信息
- 所有配置存储在浏览器本地

### English
Siphon Connector is the browser extension for Siphon Download Manager, enabling seamless download interception.

**Key Features:**
- 🚀 **Full Download Interception** — Automatically captures all browser download requests and sends them to Siphon desktop
- 🎬 **Media Sniffing** — Detects video/audio links on pages (m3u8, mpd, mp4, mp3, etc.)
- ⚡ **Multi-threaded Acceleration** — Leverages Siphon's segmented download technology for 3-5x speed improvement
- 📋 **Clipboard Monitoring** — Automatically prompts to add copied download links to Siphon
- 🎯 **Smart Filtering** — Configurable minimum file size, excluded sites, excluded extensions
- 🔔 **Desktop Notifications** — Shows notification on successful interception with one-click progress view

**Supported Browsers:**
- Google Chrome / Chromium
- Microsoft Edge
- Brave
- Mozilla Firefox

**How to Use:**
1. Install Siphon desktop app (https://github.com/XINKEJU/Siphon)
2. Install this extension
3. Extension auto-connects to Siphon, no configuration needed
4. Click download links in browser, Siphon takes over automatically

**Privacy:**
- Extension only communicates locally with Siphon desktop, no data uploaded
- Does not collect browsing history, download records, or personal information
- All settings stored locally in browser

## 分类
**Chrome Web Store：** Productivity / 生产力
**Firefox Add-ons：** Download Management / 下载管理

## 权限说明

| 权限 | 用途 |
|------|------|
| `downloads` | 拦截浏览器下载请求 |
| `contextMenus` | 右键菜单「用 Siphon 下载」 |
| `storage` | 存储扩展配置 |
| `cookies` | 透传页面 Cookie 到 Siphon |
| `webRequest` | 监控响应头获取 Content-Type |
| `scripting` | 页面媒体嗅探 |
| `tabs` | 获取当前标签页信息 |
| `nativeMessaging` | 与 Siphon 桌面端通信 |
| `notifications` | 拦截成功通知 |

## 图标尺寸要求

### Chrome Web Store
- 128x128 PNG（已包含）
- 商店截图：1280x800 或 640x400，至少 1 张，最多 5 张
- 宣传图片：440x280（小 tiles）、920x680（大 tiles）、1400x560（marquee）

### Firefox Add-ons
- 图标： PNG，至少 32x32，推荐 64x64 或更大
- 截图： PNG/JPG，推荐 1280x800，至少 1 张
- 版本：已设置为 0.4.0

## 提交步骤

### Chrome Web Store
1. 访问 https://chrome.google.com/webstore/devconsole
2. 支付 $5 开发者注册费（一次性）
3. 点击「新项目」→ 上传 `siphon-connector-chrome.zip`
4. 填写商店列表信息（使用上面的描述）
5. 上传图标和截图
6. 填写隐私政策（可使用下面的模板）
7. 提交审核（通常 1-3 个工作日）

### Firefox Add-ons (AMO)
1. 访问 https://addons.mozilla.org/developers/
2. 注册开发者账号（免费）
3. 点击「提交新加载项」→ 上传 `siphon-connector-firefox.zip`
4. 选择「托管版本」（Hosted）
5. 填写信息（使用上面的描述）
6. 填写隐私政策
7. 提交审核（通常 1-7 个工作日）

### Safari Web Extension
Safari 扩展需要通过 Mac App Store 提交，需要：
1. Apple Developer Program 会员资格（$99/年）
2. 使用 Xcode 的 Safari Web Extension 模板包装
3. 通过 App Store Connect 提交

**注意：** Safari 扩展需要额外的 Xcode 项目包装，建议单独处理。

## 隐私政策模板

```
Privacy Policy for Siphon Connector

Last Updated: 2026-11-08

Siphon Connector ("the Extension") is a browser extension that works with the Siphon desktop application.

**Data Collection**
The Extension does NOT collect, store, or transmit any personal data, browsing history, or download records to any external servers.

**Local Communication Only**
All communication occurs locally between the Extension and the Siphon desktop application running on your computer. No data leaves your device.

**Storage**
Configuration settings are stored locally in your browser's extension storage. This includes:
- Download interception preferences
- File size filters
- Excluded sites and file types
- Statistics (intercepted/skipped counts)

**Third-Party Services**
The Extension does not use any third-party analytics, advertising, or tracking services.

**Contact**
For questions about this privacy policy, please visit:
https://github.com/XINKEJU/Siphon
```

## 截图建议

建议截取以下场景：
1. **主界面** — 显示下载拦截标签页，展示统计数据
2. **媒体嗅探** — 显示检测到视频链接的列表
3. **设置页面** — 展示过滤配置选项
4. **右键菜单** — 展示「用 Siphon 下载」上下文菜单
5. **桌面通知** — 展示拦截成功时的 macOS 通知

使用 1280x800 分辨率，确保扩展弹窗清晰可见。

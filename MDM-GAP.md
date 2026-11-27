# Siphon × Mister Download Manager 差距清单与重写里程碑

> 基准：MDM `0.5.2`（Rust/egui，27.5 万行，16 crate，GPL-3.0）· Siphon 当前 `main`（Swift/SwiftUI，2.5 万行 + 4.6 千行测试，MIT）
> 口径：只列**可验证的事实**；「MDM」列均指 `../misterdownloadmanager-main/` 下的代码/文档；「Siphon」列均指本仓库。
> 图例：✅ 已对齐 · ⚠️ 有实现但不达标/半成品 · ❌ 缺失 · — 平台不适用或建议不做
> 优先级：**P0** 不补齐就不算「遵照 MDM」的核心 · **P1** 高频体验 · **P2** 长尾/生态

---

## 0. 结论（先看这里）

1. **不建议推倒重来。** Siphon 与 MDM 的技术栈（SwiftUI vs egui 自绘）没有任何可复用代码，但 Siphon 的下载核心、macOS 集成、浏览器网关、自动化接口已有大量 MDM 没有的资产（HLS/DASH 原生、eD2K、WebDAV/S3/IPFS、SCP/rsync/NFS、Metalink、边下边播、Webhook、JS 插件、RSS、Quick Look、Dock 进度、通知动作……）。
2. **「完全遵照」的正确形态 = 产品契约级对齐 + 能力补齐**：MDM 的窗口/菜单/对话框/选项/状态机/文件布局/自动化协议全部对齐，底层保留 Siphon 原生实现，并保留 Siphon 超出 MDM 的能力。
3. **体量估算**：约 110 个差距项，其中 ✅≈35、⚠️≈40、❌≈45。全部对齐约 **80–120 人日**（单人 + AI 辅助）；「P0 核心对齐」（阶段 0–2 + 阶段 4 必需项）约 **8–12 周**。
4. **三个硬约束需要先定**：
   - **许可证**：MDM 是 GPL-3.0。抄代码 → Siphon 必须 GPL；按行为 clean-room 重写 → 可保留 MIT。推荐后者。
   - **零依赖**：torrent 完整对齐、browser-like TLS 指纹这类能力，Swift 系统框架做不到 MDM 的程度；要么接受「aria2 上限内的对齐」，要么捆绑 Rust/C 辅助二进制（引入第三方与许可问题）。
   - **分发**：Developer ID 签名/公证、Safari 扩展（$99/年）都需要你的账号决策。

---

## 1. 总体对比

| 维度 | MDM | Siphon | 差距定性 |
|---|---|---|---|
| 技术栈 | Rust + egui 自绘 + winit/wgpu，跨平台 | Swift 6.4 + SwiftUI/AppKit，macOS 原生 | 不可移植，只能行为对齐 |
| 规模 | 274,534 行 Rust | 25,056 行 Swift + 4,574 行测试 | — |
| 许可 | GPL-3.0-or-later | MIT（aria2 独立进程调用） | 代码借用会传染 GPL |
| 平台 | Windows 主力 / Linux 完整 / macOS experimental | macOS 14+，26+ Liquid Glass | Siphon 平台更深 |
| 下载内核 | 自研 Rust 引擎（probe/planner/稀疏盘/resume/修复）+ librqbit | 自研 Swift NativeHTTP + aria2 RPC + 9 引擎 | 各有胜负 |
| 协议广度 | HTTP/FTP/FTPS/Torrent/视频(yt-dlp)/图库(gallery-dl)/CnL | MDM 全部 + HLS/DASH/eD2K/WebDAV/S3/IPFS/SCP/rsync/NFS/SMB/Metalink | **Siphon 更广** |
| UI 形态 | IDM 式单窗 + 每任务进度窗 + 12 页 Options | 原生三栏 + 单进度面板 + 12 页壳（半成品） | 结构需大改 |
| 自动化 | CLI + Automation API(JSON Schema) + MCP(7) + 远程 HTTPS + headless | REST + SSE + MDXP + MCP(5) + siphon:// | 缺 CLI/远程/规范 |
| 国际化 | 87 语言 + RTL + CLDR 数字 | 中英 2 语言（97 key） | 最大单项差距 |
| 扩展 | 3 平台 manifest + 51 locale + 视频浮钮 + 页面脚本 | Chromium/Firefox + 三页 popup + 无浮钮/页面脚本 | 中等差距 |
| 测试/发布 | CI + labserver 基准 + 安装器矩阵 + 崩溃报告 | verify.sh 34 步 + DMG + 未签名 | 发布链路弱 |

---

## 2. 逐项差距矩阵

### A. 主窗口与列表（13 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| A1 | 工具栏 11 项 | Add URL / Add Torrent / Resume / Stop / Stop All / Delete / Delete Completed / Options / Scheduler / Start Queue / Stop Queue（`app.rs` 工具栏数组） | 新建 / Link grabber / 「更多」ellipsis / 恢复全部 / 暂停全部 / 进度窗；无 Add Torrent、无 Start/Stop Queue | ❌ | P0 | Swift 原生 |
| A2 | 14 列列表 | 14 列可排序、拖宽、显隐、每列过滤（`list.rs`、`selection.rs`） | SwiftUI `Table` 仅 **10 列**，Peers/Share ratio/Upload speed/Save To 折叠进 Details（`TaskListView.swift:187-252`） | ⚠️ | P0 | 需 AppKit NSTableView 或自绘表格 |
| A3 | 列过滤 / Columns 窗口 | 每列过滤 + `/show columns` 列选择窗 | 无列过滤、无 Columns 窗口 | ❌ | P0 | Swift 原生 |
| A4 | Find 窗口 | 独立 Find + Find Next（`find.rs`） | 已有 `.searchable` + 查找下一个对话框 | ✅ | — | — |
| A5 | 预览窗格 Alt+P | 缩略图预览侧栏（`preview.rs`） | 有 Quick Look（⌘Y）与检查器，无预览窗格 | ⚠️ | P1 | Swift 原生 |
| A6 | 拖放 / 批量 / 剪贴板批量 | droptarget + Batch + 剪贴板批量（`batch.rs`、`clipbatch.rs`） | 拖放 ✅、多行批量 ✅、剪贴板单条 ✅；无 MDM 的批量对话框（星号/数字/字母序列）与剪贴板批量导入 | ⚠️ | P1 | Swift 原生 |
| A7 | Recent 应用内视图 | 弹窗“最近下载”数据 + `info/OnDisk`（`recent.rs`） | 仅 `GET /recent`，App 内无 Recent 菜单/视图 | ⚠️ | P2 | Swift 原生 |
| A8 | 完成分组摘要 | 同组只弹一个 “Downloads complete”（`finish.rs`） | 每任务单独通知 | ⚠️ | P2 | Swift 原生 |
| A9 | 菜单结构 | Tasks/File/Downloads/View/Help 全动作入口 | 已有同名 5 菜单，但动作集合与 MDM 不一致 | ⚠️ | P0 | Swift 原生 |
| A10 | 快捷键表 | 完整表（`docs/keyboard-shortcuts.md`） | 有常用快捷键，未对齐全表 | ⚠️ | P1 | Swift 原生 |
| A11 | 工具栏“更多”移除 | MDM 无 ellipsis；所有动作直达 | ellipsis 仍在（`ContentView.swift:275-288`），且 README §7.3 声称已移除 | ⚠️ | P0 | Swift 原生 |
| A12 | 顶部筛选 | MDM 用列过滤 + 分类树 | `filter` 恒为 `.all`，README §7.4 声称有筛选标签 | ⚠️ | P1 | Swift 原生（可并入 A3） |
| A13 | 窗口行为 | 固定像素布局 + 立即 viewport 对话框 | 原生窗口，布局已基本对齐 | ✅ | — | — |

### B. 进度窗口（7 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| B1 | 每任务独立窗口 | 每个下载各自一个进度窗（`progress.rs`） | 单例面板复用（`MDMProgressPanel.swift:11-30`） | ⚠️ | P0 | Swift 原生 |
| B2 | 三 tab：Status/Limiter/Completion | 完整三 tab（`progress.rs:93-105`） | 三 tab 已有 | ✅ | — | — |
| B3 | 连接表（服务器/速度/进度/国家/RTT） | 连接表 + geo 国家 + RTT（`server.rs`、`mdm-geo`） | 连接表有；国家/RTT 恒 nil（`ProductContract.swift`） | ⚠️ | P1 | Swift 原生（IP→国家需离线表，P2） |
| B4 | 事件流 | 引擎事件进度/完成/失败 | `events=[]` 恒空 | ⚠️ | P1 | Swift 原生 |
| B5 | Stop and keep（直播保流） | `Download::keep` 保留已收字节 | HLS live 有录制；NativeHTTP 无“停止并保留”语义 | ⚠️ | P1 | Swift 原生 |
| B6 | 隐藏 tab / 重显 | 右键 Hide tab / Show hidden tabs | 无 | ❌ | P2 | Swift 原生 |
| B7 | Torrent 五 tab | Files/Peers/Trackers/Pieces/General | 无 torrent 专属窗口 | ❌ | P1 | 见 I 组 |

### C. 分类与文件类型（5 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| C1 | 用户自定义分类 | Add/Properties/Delete + 删除时迁移（`categories.rs`） | 固定枚举 7 类，无增删改（`ProductStatus.swift`） | ❌ | P0 | Swift 原生 |
| C2 | 每分类独立文件夹 | Save to 页可配（`options.rs`） | 仅单一下载目录 | ❌ | P0 | Swift 原生 |
| C3 | 文件类型映射可编辑 | 扩展名→类别映射（File types 页） | 只读硬编码清单（`MDMOptionsView.swift:105-128`） | ⚠️ | P0 | Swift 原生 |
| C4 | 分类计数 | 树节点显示数量 | 有 | ✅ | — | — |
| C5 | Torrents 独立分类 | 有 | 有 | ✅ | — | — |

### D. Options 12 页（12 项）

| # | 页 | MDM 关键内容 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| D1 | General | 托盘点击行为、全局热键、剪贴板、浏览器选择、按钮大小、Keys | 通用设置（下载位置/后台/菜单栏样式/冲突策略/系统集成…） | ⚠️ | P0 | Swift 原生 |
| D2 | File types | 自动开始类别、扩展名映射、排除 | 只读清单 | ⚠️ | P0 | 见 C3 |
| D3 | Save to | 默认/分类/临时目录、空间策略 | 仅下载目录 | ⚠️ | P0 | Swift 原生 |
| D4 | Downloads | 默认连接/重试/UA/完成动作/进度窗行为 | 分散在“速度/通用”，缺重试与进度窗行为 | ⚠️ | P0 | Swift 原生 |
| D5 | Connection | 1–32/128 连接、服务器例外、Site rules、超时、browser-like | 有每主机规则，缺例外表/超时/browser-like | ⚠️ | P0 | Swift 原生 |
| D6 | Proxy / Socks | 手动/PAC/SOCKS/DNS(系统/DoH/DoT)/适配器绑定/例外 | 手动 HTTP/SOCKS5 + PAC；无 DoH/DoT、无 kill-switch | ⚠️ | P1 | Swift 原生 |
| D7 | Sites Logins | 站点用户名/密码列表 | 有站点规则与 Cookie，无登录列表 | ⚠️ | P1 | Swift 原生 |
| D8 | Accounts | 5 家 debrid 登录 | 文案占位（`MDMOptionsView.swift:191-199`） | ❌ | P1 | 见 J 组 |
| D9 | Sounds | 事件音效开关 + 文件 | 开关存在但无消费者（grep `soundsEnabled` 仅 1 处） | ⚠️ | P2 | Swift 原生 |
| D10 | Regional | 语言、数字/日期、界面大小 | 仅中英语言 Picker | ⚠️ | P1 | 见 O 组 |
| D11 | Archives | 自动解压、7-Zip 路径、密码、归档测试、修复策略 | 有自动解压（zip/tar/gz/7z），无密码列表/测试/修复 | ⚠️ | P1 | Swift + 7z 外挂 |
| D12 | Remote | 开关、监听、证书指纹、配对、设备 | 配对已有，无 HTTPS 服务/页面/指纹 | ⚠️ | P1 | 见 M 组 |

### E. 下载核心（18 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| E1 | HTTP/HTTPS | 自研 Rust 引擎 | 自研 NativeHTTP（1938 行） | ✅ | — | — |
| E2 | FTP/FTPS | 原生 FTP/FTPS 规划+worker | URLSession/curl 承担；实际可用性未复测 | ⚠️ | P1 | Swift 原生补强 |
| E3 | 探测 + 单连接起步 | 第一条连接持续流式读，其余并行 | 有 Range/HEAD 探测；首连接策略不同 | ⚠️ | P2 | 行为对齐 |
| E4 | 动态分段 | 纯逻辑 Planner、preempt、最大段对半 | work-stealing + 慢段抢占 | ✅ | — | — |
| E5 | 稀疏 part 文件 | 位置写入稀疏盘（`sparse.rs`） | `F_PREALLOCATE` 预分配 | ⚠️ | P2 | 可选对齐 |
| E6 | 续传安全 | `.mdm.json` + If-Range + 重叠校验 + 摘要 | sidecar + 指纹，变化即重下；无重叠校验证据 | ⚠️ | P1 | Swift 原生 |
| E7 | 校验算法 | CRC32/MD5/SHA-1/256/512 + 服务器 `Digest`/`Content-MD5` | MD5/SHA-1/256/384/512；缺 CRC32 与服务器摘要头 | ⚠️ | P0 | Swift 原生 |
| E8 | 限速 | 每下载 + 全局 + “仅使用时” | 全局/单任务/乌龟；无“仅使用时” | ⚠️ | P2 | Swift 原生 |
| E9 | 每主机学习上限 | 观察 2 次后限流，10 分钟衰减（`hosts.rs`） | 有每主机静态规则 + HostHealth，无学习上限 | ⚠️ | P1 | Swift 原生 |
| E10 | 慢连接丢弃 | 有 | 有（慢段抢占） | ✅ | — | — |
| E11 | 连接数上限 | 1–32，解锁至 128 | 进度面板 1…32 | ⚠️ | P2 | Swift 原生 |
| E12 | 代理/PAC | 手动/PAC(QuickJS)/SOCKS | 手动 + PAC(JavaScriptCore)；`isResolvable/isInNet` 为桩 | ⚠️ | P1 | Swift 原生 |
| E13 | DNS | 系统/DoH/DoT/自定义 + 竞速 | 系统 DNS | ❌ | P2 | Swift 原生（Network.framework） |
| E14 | 适配器绑定 kill-switch | 绑定即断网，适配器消失即失败 | 多网卡分流（≥256MB），非 fail-closed | ⚠️ | P2 | Swift 原生 |
| E15 | 根证书 | 系统 + Mozilla 根 | 系统根（URLSession） | ⚠️ | P2 | 可选 |
| E16 | 默认浏览器 UA | 启动探测默认浏览器 UA | UA 固定 `Siphon/<ver>` | ⚠️ | P1 | Swift 原生 |
| E17 | 浏览器式连接重试 | BoringSSL 指纹级重试（`browserlike.rs`） | 无 | ❌ | P2 | 需 curl-impersonate 类 helper 或放弃 |
| E18 | 站点适配 | gdrive/mediafire/rapidgator/lulustream/gofile/archive.org | 无 | ❌ | P1 | Swift 原生（行为 clean-room） |

### F. Link grabber / 远程 ZIP / 归档（10 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| F1 | 页面链接抓取 | HTML 链接/媒体/refresh（`html.rs`） | 无 HTML 页面解析 | ❌ | P1 | Swift 原生 |
| F2 | FTP/“Index of” 文件夹包 | `folder.rs`，递归、上限 10k/500 | 有 FTP/WebDAV 列目录，非包式抓取 | ⚠️ | P1 | Swift 原生 |
| F3 | Hugging Face 仓库/目录包 | `hub.rs` + SHA-256 | 无 | ❌ | P1 | Swift 原生 |
| F4 | GitHub release/tag 包 | `hub.rs` | 无 | ❌ | P1 | Swift 原生 |
| F5 | 远程 ZIP 预览 | `remotezip.rs`，尾部读目录 + ZIP64 | 无 | ❌ | P1 | Swift 原生 |
| F6 | 选择性解包下载 | 只取所选文件 | 无 | ❌ | P1 | Swift 原生 |
| F7 | 归档测试 | ZIP 进程内 + 7z t（`check.rs`） | 仅解压，无测试 | ❌ | P1 | Swift + 7z |
| F8 | 损坏归档修复 | 只重下坏字节（`repair.rs`） | 无 | ❌ | P1 | Swift 原生 |
| F9 | Click'n'Load 2 | 127.0.0.1:9666，AES-128-CBC | 无 | ❌ | P1 | Swift 原生 |
| F10 | 包/勾选/保存树 | 包与勾选、子目录 | LinkGrabber 仅多行 URL | ⚠️ | P1 | Swift 原生 |
| F11 | HatchZip 就地解压 | 支持 | 无 | ❌ | P2 | 不做/可选 |

### G. 视频与图库（8 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| G1 | yt-dlp 基础下载 | 全链路（多连接/HLS/DASH/AES/直播） | 有（并发分片、合并、续传） | ✅ | — | — |
| G2 | 质量/字幕/章节/片段选择 | 视频对话框 | 无 | ❌ | P1 | Swift 原生 + yt-dlp |
| G3 | 播放列表/频道选集 | 上限 20000 | 仅 M3U/PLS 导入 | ❌ | P1 | Swift 原生 |
| G4 | 直播录制 | 有 | HLS live 有；yt-dlp live 未接 | ⚠️ | P2 | Swift 原生 |
| G5 | helper 安装/更新 | yt-dlp/ffmpeg/gallery-dl/JS 运行时 | 查找二进制，无安装更新 UI | ⚠️ | P1 | Swift 原生 |
| G6 | gallery-dl 图库 | 4 并发、站点适配 | 无 | ❌ | P1 | 外部二进制 |
| G7 | 图库对话框 | 有 | 无 | ❌ | P1 | Swift 原生 |
| G8 | 原生 HLS/DASH | 无（走 yt-dlp） | 有（Siphon 优势） | ✅ 保留 | — | — |

### H. Torrent（15 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| H1 | 内核 | librqbit（fork） | aria2 JSON-RPC | ✅（不同内核） | — | — |
| H2 | magnet/.torrent | 有 | 有 | ✅ | — | — |
| H3 | 文件选择 | 有（含未选文件磁盘归属） | 有（`applyBTFileSelection`） | ✅ | — | — |
| H4 | 五 tab 详情 | Files/Peers/Trackers/Pieces/General | 仅 Details 列 | ❌ | P1 | aria2 数据 + 自绘 |
| H5 | 做种目标 | 比率/时间/策略 | aria2 `seed-ratio` 可配，无按任务面板 | ⚠️ | P1 | Swift 原生 |
| H6 | 全局上传限速 | 有（≥16KB/s 步进） | 未暴露 | ⚠️ | P2 | aria2 选项 |
| H7 | 每任务上传限速 | librqbit fork | aria2 不支持 | ❌ | P2 | 需新内核/放弃 |
| H8 | Blocklist | PeerGuardian/eMule .dat | 无 | ❌ | P2 | aria2 不支持，需新内核/放弃 |
| H9 | 公共 tracker 注入 | 有 | 有（TrackerManager） | ✅ | — | — |
| H10 | 顺序下载 | 有 | 未暴露 | ❌ | P1 | aria2 `bt-sequential` |
| H11 | Recheck | 有 | 未暴露 | ❌ | P2 | aria2 `--check-integrity` |
| H12 | 多文件重命名 | 插件实现 | 不支持 | ❌ | P2 | aria2 不支持，需新内核/放弃 |
| H13 | 安全开关（DHT/LSD/UPnP/uTP/SOCKS-only） | 有 | 部分（UPnP/NAT-PMP） | ⚠️ | P1 | aria2 选项 |
| H14 | RSS 规则 | 剧集语法 | 有（正则/上限/队列/子目录） | ⚠️ | P2 | Swift 原生 |
| H15 | 监视文件夹 | **MDM 也没有** | 无 | — | — | 不做 |

> **决策点**：H7/H8/H12 三项在 aria2 上无解。若必须 100% 对齐，需捆绑 librqbit（Rust）helper；否则接受 aria2 能力上限并明确标注差异。

### I. Debrid 与账号（3 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| I1 | 5 家 debrid | Real-Debrid/AllDebrid/Premiumize/TorBox/Mega-Debrid | 无 | ❌ | P1 | Swift 原生 |
| I2 | 直链解锁不下泄 | `unlock.rs`，不进列表/日志 | 无 | ❌ | P1 | Swift 原生 |
| I3 | debrid torrents | 有 | 无 | ❌ | P2 | Swift 原生 |

### J. 队列 / 调度 / 完成动作（9 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| J1 | 队列 CRUD/并发/优先级/时段/限速 | 有 | 有 | ✅ | — | — |
| J2 | Scheduler 两页窗口 | Schedule / Files in queue | 有简化对话框 | ⚠️ | P1 | Swift 原生 |
| J3 | 一次性/每日/启动时启动 | 有 | 时段窗有；缺一次性/启动时 | ⚠️ | P1 | Swift 原生 |
| J4 | 停止时间/重试 | 有 | 部分 | ⚠️ | P1 | Swift 原生 |
| J5 | 定时唤醒 | 电源计划/wakealarm/pmset | 系统唤醒后立即评估时段窗口并恢复；不做需 root 的 RTC 唤醒（pmset schedule wake 需 sudo） | ⚠️ | P1 | Swift 原生（IOPMAssertion/pmset） |
| J6 | 完成动作 | 打开/挂断/退出/关机/睡眠/休眠 + 倒计时 | 睡眠/关机/退 App | ⚠️ | P2 | Swift 原生 |
| J7 | 下载限额 N MB/H | 有（`quota.rs`） | 每小时 N MB：达到后暂停活动任务，整点自动恢复（只恢复因限额暂停的）；设置 → 速度 | ✅ | — | — |
| J8 | 分组完成通知 | 有 | 每任务 | ⚠️ | P2 | Swift 原生 |
| J9 | “仅在我使用电脑时”限速 | 有 | 无 | ❌ | P2 | Swift 原生 |

### K. 浏览器集成与扩展（16 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| K1 | Chromium MV3 | 有 | 有（v0.5.0） | ✅ | — | — |
| K2 | Firefox MV3 | 有（min 140） | 有 | ✅ | — | — |
| K3 | Safari | manifest 存在 | 无（`dist/safari/` 空） | ❌ | P2 | 需 Apple 账号 + Xcode 包装 |
| K4 | popup 三页 | Downloads/This page/Settings | 三页已有 | ✅ | — | — |
| K5 | 视频浮钮 | `video.js` 覆盖按钮，多状态/菜单 | 无注入脚本 | ❌ | P1 | JS 原生 |
| K6 | 页面早期拦截 | `page.js` document_start | 无 | ❌ | P1 | JS 原生 |
| K7 | 本页媒体（HLS/DASH/DRM） | 识别 + 发送 | webRequest 嗅探媒体列表 | ⚠️ | P1 | JS 原生 |
| K8 | 本页图片→Link grabber | 有 | 无 | ❌ | P2 | JS 原生 |
| K9 | 扩展 locale | 51 个 | 无 | ❌ | P2 | 翻译流水线 |
| K10 | 接管规则（文件类型/站点/大小） | 有，与 app 设置同步 | 有基础过滤 + 排除 | ⚠️ | P1 | 对齐 |
| K11 | 表单重放 | 有 | 无 | ❌ | P2 | JS + 引擎 |
| K12 | 未接管/手动提示 | 有 | 部分 | ⚠️ | P2 | 对齐 |
| K13 | Recent 列表 | 有 | 有 `/recent` | ✅ | — | — |
| K14 | 原生网关安装 | 安装程序写入 + app 提示 | 手动填扩展 ID + 安装按钮 | ⚠️ | P1 | Swift 原生 |
| K15 | 自动绑定 | MDM 无此概念（安装器绑定） | 已改手动 | ⚠️ | P2 | 对齐 MDM 模式 |
| K16 | 版本一致性 | — | App 0.5.0 = 扩展 0.5.0 | ✅ | P0 | 已统一 |

### L. 自动化与远程（9 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| L1 | CLI 子命令 | 25+（get/resume/status/list/pause/…/torrent-*/video-*/gallery-*） | 无 CLI | ❌ | P1 | Swift 原生（手写参数解析） |
| L2 | IDM 式启动开关 | `/d /p /f /a /n /s /exit /startup` | 无 | ❌ | P2 | Swift 原生 |
| L3 | Automation API + JSON Schema | 127.0.0.1 + token + 幂等 id + 错误码 + schema | REST 已有（/tasks、/add 等），无 schema/幂等契约 | ⚠️ | P1 | Swift 原生 |
| L4 | MCP 工具 | 7 个（含 queue 操作 + 过滤） | 5 个 | ⚠️ | P1 | Swift 原生 |
| L5 | MCP server card | `/.well-known/mcp/server-card.json` | 无 | ❌ | P2 | 静态文件 |
| L6 | 远程 HTTPS 控制 | axum + 自签证书 + 指纹 + 8 位配对 + 二维码 + 内置 Web 页面 + 设备令牌 | 有配对状态机；无 HTTPS 服务/页面/二维码 | ⚠️ | P1 | Swift 原生（Network.framework + CIQRCodeGenerator） |
| L7 | headless/服务器模式 | `--headless`、Docker/Unraid | 无 | ❌ | P2 | 可选做（macOS 场景弱） |
| L8 | 服务器环境变量 | `MDM_DATA_DIR` 等 | `SIPHON_DATA_DIR` 已有 | ✅ | — | — |
| L9 | 手机/远程页面 | 自带 Web app | 无 | ❌ | P1 | 见 L6 |

### M. 系统集成（12 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| M1 | 菜单栏/托盘状态 | 三平台托盘 + 面板 | 菜单栏状态文本 | ✅（基础） | — | — |
| M2 | 托盘下载面板 | 每任务进度/暂停/取消 | 左键 NSPopover 面板：每任务进度/暂停/继续、全部暂停/恢复、主窗口/设置/退出；右键保留菜单 | ✅ | — | — |
| M3 | 全局显示/隐藏热键 | 2–3 键组合 | Carbon ⌥⌘D 全局显示/隐藏，可在通用设置关闭 | ✅ | — | — |
| M4 | 事件音效 | 完成/失败等 | 无 | ❌ | P2 | NSSound |
| M5 | 通知 | 完成/组完成/更新/限额 | 通知 + 动作 | ✅ | — | — |
| M6 | Dock 进度/菜单 | macOS Dock 进度 | 有 | ✅ | — | — |
| M7 | Quick Look | 无（Windows 预览窗格） | 有 | ✅ 保留 | — | — |
| M8 | 删除进废纸篓 | 各平台 | 有 | ✅ | — | — |
| M9 | 下载来源/quarantine | MotW/quarantine | 有（kMDItemWhereFroms + quarantine） | ✅ | — | — |
| M10 | Services/URL scheme | .torrent/magnet 关联 | 有（33 scheme + Services） | ✅ | — | — |
| M11 | 网络感知自动暂停 | 有（netwatch） | 有 | ✅ | — | — |
| M12 | 开机自启 | 有 | 有 | ✅ | — | — |

### N. 主题 / 缩放 / i18n（10 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| N1 | 10 套主题 | Classic/Native/High contrast/Metro/Adwaita/Breeze/Luna/Aero/Aqua/Emerald | 10 套 + 22 角色已建 | ✅ | — | — |
| N2 | 主题覆盖全界面 | 所有控件取色 | 主窗口/分类树/列表/详情/全部对话框/下载弹窗/菜单栏面板/Options/设置均消费主题；外观切换作用于整个 App | ✅ | — | — |
| N3 | 自定义主题文件 | TOML/JSON + inherits | 无 | ❌ | P2 | Swift 原生 |
| N4 | Base16/pywal 实时 | 有 | 无 | ❌ | P2 | 可选 |
| N5 | 界面缩放 100–200% 生效 | 全界面 | 表格、对话框、弹窗按 scale 缩放字号/行高；系统文本样式经 dynamicTypeSize 同步 | ✅ | — | — |
| N6 | 87 语言 | 88 个 TSV（87 语言） | 中英 2 语言（97 key） | ❌ | P1 | 分批 + 机器翻译 |
| N7 | RTL | ar/he/fa/ur/ug | 无 | ❌ | P1 | SwiftUI 天然支持 + 布局检查 |
| N8 | CLDR 数字/日期 | 有 | 系统默认 | ⚠️ | P2 | Foundation Locale |
| N9 | i18n 工具链 | extract/translate/glossary/style | tools/i18n/extract.py（仅 en） | ⚠️ | P1 | 扩展工具链 |
| N10 | 图标集 4 尺寸 | 有 | 系统符号 | ⚠️ | P2 | 可选 |

### O. 崩溃 / 更新 / 便携 / 发布（10 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| O1 | 崩溃监视器 + minidump | 有（`mdm-crash`） | 无 | ❌ | P2 | Swift signal handler（受限） |
| O2 | 符号化堆栈 | rust-minidump | 无 | ❌ | P2 | atos |
| O3 | 冻结看门狗 | 8 秒 | 无 | ❌ | P2 | 自研心跳 |
| O4 | 日志 | logs/ 2MB 轮转 | `~/Library/Logs/Siphon/siphon.log`，2 MB 轮转保留 1 份；记录提交与终态，设置页可打开 | ✅ | — | — |
| O5 | 更新器 | 签名校验 + 替换 + 重启 | 有（feed 默认空） | ⚠️ | P0 | 填默认 feed + 发版 |
| O6 | 便携模式 | portable.zip | 无 | ❌ | 不做（macOS 弱需求） | — |
| O7 | 单实例 | token socket | flock | ✅ | — | — |
| O8 | DMG/安装器 | 全平台矩阵 | DMG 脚本 | ✅（macOS） | — | — |
| O9 | 签名/公证 | 未签名（README） | 脚本就位、无凭据 | ⚠️ | P1 | 需你的 Developer ID |
| O10 | 版本一致性 | — | 0.5.0（App = 扩展） | ✅ | P0 | 已统一 |

### P. 生态层（7 项）

| # | 能力 | MDM 事实 | Siphon 现状 | 差距 | 优先级 | 路径 |
|---|---|---|---|---|---|---|
| P1 | 帮助文档 34 篇 | `docs/*.md` 全量 | 仅 README | ❌ | P2 | 文档工程 |
| P2 | 官网 21 语言 | `website/` + build.py | 无 | ❌ | 不做/可选 | — |
| P3 | 基准报告 | labserver + 7 场景 | verify 有测试，无公开基准 | ❌ | P2 | 可选 |
| P4 | 商店提交包 | Chrome/Firefox/Safari | Chromium/Firefox 已打包 | ✅ | — | — |
| P5 | 崩溃报告页/问题模板 | 有 | 无 | ❌ | P2 | 文档 |
| P6 | WinGet/SourceForge | 有 | — | 不做 | — | — |
| P7 | Docker/Unraid | 有 | — | 不做 | — | — |

---

## 3. Siphon 已超出 MDM、必须保留的能力

- **协议**：HLS（AES-128/BYTERANGE/MAP/live）、DASH（AVFoundation 扁平化）、eD2K 原生 TCP、WebDAV、S3 SigV4、IPFS/IPNS、Metalink、SCP/rsync/NFS、SMB/SMBS、curl 协议族、本地/`data:`、播放列表。
- **系统**：Quick Look、Dock 进度/菜单、端口映射 UPnP/NAT-PMP、边下边播（Range 回环服务）、Services、WhereFroms、网络感知暂停、开机自启。
- **平台集成**：MDXP JSON-RPC、Webhook（HMAC + SSRF 防护）、JS 插件、RSS、Tracker 自动更新、单任务 Boost、乌龟模式、断点 sidecar、多网卡。
- **注意**：这些能力的 UI 入口/契约也要纳入 MDM 的 Options/菜单体系，而不是删掉。

---

## 4. 分阶段重写计划（每阶段可编译 + verify.sh 通过 + UI 由你验收）

> Siphon 验收惯例：我跑 `swift build` 与 `scripts/verify.sh`（34 步）；界面效果由你在真机 App 中确认。提交/推送分开指令。

### 阶段 0 — 口径统一与先修（约 3–5 天）
- ✅ 修 `ProxyRouter.loadPAC` NSLock 不平衡（`ProxyRouter.swift:213-223`）。
- ✅ AddURL 的 Save-to/Category/Description 接通到 `MDMCommand` → bridge（目录、分类落盘并持久化）。
- ✅ 版本号统一（App 0.5.0 / 扩展 0.5.0 / Info.plist build 5）。
- ✅ README 与实现不一致处修正（14 列、ellipsis、筛选标签、`/ping` 令牌、路线图第 8 条）。
- ✅ 删除死代码 `SidebarView` / `SpeedGraphView`。
- 验收：34 步 verify 全过；文档口径一致。

### 阶段 1 — UI 与选项完全对齐（约 10–15 天）
- 14 列列表（AppKit NSTableView 或自绘）：列过滤、列显隐（Columns 窗）、列宽持久化。
- 工具栏 11 项直达、去掉 ellipsis；菜单动作对齐；快捷键表对齐。
- 每任务进度窗口（普通 3 tab；torrent 5 tab）；Stop and keep；tab 隐藏。
- 分类：用户自定义分类 + 每分类文件夹 + 文件类型映射可编辑。
- Options 12 页真实内容（D1–D5、D7、D9、D11 先行；D8/D12 待后续阶段）。
- Find/Columns/Batch/Recent 对话框补齐。
- 验收：`swift build` + verify + 你按窗口逐项截图验收。

### 阶段 2 — 引擎/站点/抓取/归档/视频图库（约 20–30 天）
- 站点适配 6 家（行为 clean-room）；UA 探测；CRC32 + 服务器摘要头；每主机学习上限；重叠校验；FTP 补强。
- Link grabber：HTML 页面、FTP/Index-of 文件夹包、HF/GitHub 包（SHA-256）、包/勾选/保存树。
- 远程 ZIP 预览 + 选择性下载；归档测试 + 损坏修复；CnL 2。
- 视频：质量/字幕/章节/片段对话框、播放列表/频道、helper 安装；gallery-dl 图库。
- Debrid 5 家 + 直链解锁（密钥进 Keychain）。
- 验收：本地 lab 场景 + verify 新步骤；站点适配用公开测试链接。

### 阶段 3 — Torrent 完整化（约 10–15 天，或 +20 天需新内核）
- aria2 路线：五 tab 详情、顺序下载、recheck、做种策略面板、全局上传限速、安全开关、RSS 剧集规则。
- 需你决策：H7/H8/H12（每任务上传限速/Blocklist/重命名）是否接受“无”，或捆绑 librqbit helper。
- 验收：magnet/.torrent 全流程 + 五 tab 数据真实性。

### 阶段 4 — 自动化与系统集成（约 15–25 天）
- CLI（`--cli get/resume/...`）+ Automation API schema/幂等/错误码 + MCP 7 工具 + server card。
- 远程 HTTPS 控制：自签证书、指纹、配对（已有）、二维码、Web 页面、设备令牌。
- 菜单栏下载面板；全局显示/隐藏热键；事件音效；日志；Scheduler 唤醒/重试/限额。
- 验收：本地 CLI 端到端 + 手机/浏览器访问远程页（你自验）。

### 阶段 5 — i18n / 主题 / 发布（约 20–30 天）
- i18n 架构 + 首批语言（建议 10–15 种，中英完整）；RTL；CLDR 数字/日期；界面缩放全应用。
- 主题覆盖全界面；自定义主题文件（可选 Base16/pywal）。
- 发布：默认更新 feed + 版本一致性 + DMG 签名/公证（需 Developer ID）+ Safari 扩展（需 $99/年，待定）。
- 帮助文档（可从 34 篇翻译/裁剪）；基准报告可选。
- 验收：多语言截图（你提供）、verify 全过、可分发 DMG。

---

## 5. 三条路线与推荐

| 路线 | 做法 | 优点 | 代价 | 结论 |
|---|---|---|---|---|
| **A. Clean-room Swift 全对齐（推荐）** | 按本清单分阶段重写交互与缺项，保留 Siphon 引擎/系统集成 | 保留 MIT、零 Swift 依赖、原生体验、现有 2.5 万行资产 | 工期最长；torrent/browser-like 只能到 aria2/系统框架上限 | **推荐主线** |
| B. Rust 接管（fork MDM 换皮） | 用 MDM 全套代码，改品牌/构建 | 100% 遵照、立刻可用 | 放弃 Swift/MIT/现有资产；GPL 传染；macOS 仍是 experimental；egui 非原生 | 不推荐（除非你只想要 MDM） |
| C. Swift 主体 + Rust helper | A 为主，torrent/browser-like 用捆绑 helper（librqbit / curl-impersonate） | 关键能力 100% 对齐 | 引入第三方二进制、许可与签名复杂、构建链变重 | 可选，仅在必须 H7/H8/H12 时 |

**我的建议**：走 A；阶段 0–2 先做（P0 核心），阶段 3 的 H7/H8/H12 若你不在意可明确标注为「MDM 无 aria2 等价实现」；阶段 4–5 按需推进。

---

## 6. 已定决策（2026-11-26）

1. **路线 A**：Swift 原生全对齐；保留现有 Siphon 引擎与系统集成。
2. **许可证**：保留 MIT；对 MDM 只做行为级 clean-room，禁止拷入任何 GPL 代码/资源/主题/文案。
3. **Torrent**：两段走——先按 aria2 上限对齐（3.1–3.2），再捆绑 librqbit 独立进程补齐 H7/H8/H12（3.3–3.4）；上游许可与签名链在实施前核对。
4. **i18n**：先做架构 + 首批 12 种语言（中简/中繁/英/日/韩/德/法/西/葡-BR/俄/阿/RTL 验证/土），其余后续分批。
5. **签名与 Safari**：暂缓，单独决策；阶段 5 先完成更新 feed、版本一致性与发布包。

> 优先级确认：先完成六块大头——UI 结构（14 列/每任务进度窗/自定义分类/Options 12 页）、下载能力（站点/HF-GitHub/FTP 包/远程 ZIP/归档修复/CnL/debrid）、Torrent 完整化、自动化（CLI/Schema/MCP 7/远程 HTTPS）、i18n 与主题全覆盖。

---

## 7. 风险清单

- **SwiftUI Table 10 列限制**：14 列必须换 AppKit 表格（阶段 1 最大不确定项）。
- **GPL 传染**：任何 MDM 代码/资源（含主题 TOML、图标、文案）都不能进 MIT 仓库；只能学行为。
- **aria2 能力上限**：每任务上传限速、blocklist、多文件重命名无解。
- **零依赖 vs helper**：librqbit/curl-impersonate 会打破“纯系统框架”叙事，并影响签名/公证与更新链。
- **87 语言**：机器翻译质量与维护成本极高；建议分批。
- **未签名/未公证**：目前 adhoc，Gatekeeper 会拦；更新链需签名身份。
- **测试形态**：verify.sh 是手写 CLI 套件；大改 UI 后需补 UI 冒烟（截图验收）。
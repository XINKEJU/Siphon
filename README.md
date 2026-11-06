# Siphon · 虹吸

<p align="center">
  <img src="Resources/AppIcon-Preview.png" width="180" alt="Siphon macOS app icon">
</p>

<p align="center">
  <img src="Resources/UI-Preview.png" width="720" alt="Siphon Liquid Glass interface on macOS 27">
</p>

面向 macOS 的原生全协议下载管理器。核心思路：**用 aria2 做久经考验的下载内核，用 Swift 补齐 aria2 不擅长的协议，用 SwiftUI/AppKit 做符合 macOS HIG、macOS 26+ 液态玻璃（Liquid Glass）的原生界面。**

> **为什么叫虹吸**：虹吸跨过落差，靠一根连续管道把远端的流体自发引到本处。aria2 是自持内核，多协议与多分段是入流，落盘的单一文件是出流。

- 语言：Swift 6.4（Swift 5.10 工具链兼容模式）
- 最低系统：macOS 14 (Sonoma)；**macOS 26+ 启用完整液态玻璃外观**，14/15 自动降级为材质外观（同一二进制）
- 依赖：零第三方 Swift 包。仅系统框架（Foundation / SwiftUI / AppKit / Network / CommonCrypto）
- 外部二进制：`aria2c`（捆绑，运行必需）；`ffmpeg`（可选，用于 fMP4 重封装）
- 许可证：MIT（详见 [LICENSE](LICENSE)）；aria2 以独立进程调用，见 §11

---

## 1. 为什么这样设计

在对比了 aria2、FluxDown、Gopeed、AB Download Manager、Motrix、Persepolis、HyperDM 七个项目后，取舍如下：

| 需求 | 决策 |
|---|---|
| 稳定 + 性能 | aria2（C++，20 年验证）承担主流协议，Swift 只做编排 |
| 小体积 | Swift 原生编译，无 Electron / Flutter / JVM 运行时；aria2c 单文件约 3–5 MB |
| 全协议 | aria2 覆盖 HTTP(S)/FTP/SFTP/BT/Metalink/磁力；原生引擎补 HLS / DASH / eD2K |
| 真原生 | SwiftUI + AppKit，`.app` bundle，非 WebView 外壳 |
| 集各家所长 | 队列与调度（AB DM / HyperDM）、限速（Motrix / HyperDM）、剪贴板监听（HyperDM）、浏览器/REST 集成（Gopeed / AB DM）、aria2 JSON-RPC（Motrix / Persepolis） |

**许可证关键**：aria2 是 GPLv2。本工程以**独立进程 + JSON-RPC**调用 aria2c，不链接 `libaria2`、不合并二进制，因此应用自身不必 GPL 化。若改为链接 libaria2，需重新评估合规义务。

---

## 2. 协议矩阵

| 协议 | 实现 | 状态 |
|---|---|---|
| HTTP / HTTPS | aria2（多连接分段、断点续传） | ✅ 完整 |
| FTP / SFTP | aria2 | ✅ 完整 |
| BitTorrent / 磁力 / Metalink | aria2（DHT / PEX / WebSeed / 选择性下载） | ✅ 完整 |
| HLS (`.m3u8`) | Swift 原生：master/media 播放列表、`EXT-X-KEY` AES-128、`EXT-X-BYTERANGE` | ✅ 可用（TS 流） |
| DASH (`.mpd`) | Swift 原生：SegmentTemplate（`$Number$`/`$RepresentationID$`）、SegmentTimeline、SegmentList | ✅ 可用（fMP4 字节流） |
| eD2K (`ed2k://`) | MD4、eD2K 哈希、`ed2k://` 链接解析、哈希校验 + 后端抽象 | ⚠️ 传输后端待接入，见 §5 |

原生 HLS/DASH 共用 `SegmentAssembler`：有界并发、严格有序落盘、按段断点续传、令牌桶限速。

---

## 3. 构建与运行

```bash
cd Siphon

# 1) 验证：编译 + MD4 官方向量 + HLS/DASH 解析 + 并发有序落盘端到端测试
./scripts/verify.sh

# 2) 仅编译
swift build

# 3) 生成可双击运行的 .app（自动捆绑图标、aria2c / ffmpeg 及其依赖库）
brew install aria2            # 若尚未安装
./scripts/build-app.sh
open build/Siphon.app

# 4) 从矢量源重新生成应用图标（改了 scripts/MakeIcon.swift 后执行）
./scripts/make-icon.sh

# 5) 生成可拖拽安装的 DMG（自动挂载校验签名后卸载）
./scripts/make-dmg.sh
```

`build-app.sh` 在缺少 `Resources/AppIcon.icns` 时会自动调用 `make-icon.sh`，因此全新 clone 后一条命令即可得到带图标的 `.app`。安装时把 `build/Siphon.app` 拖进「应用程序」，或挂载 `build/Siphon-0.1.0.dmg` 拖入其中的 Applications 快捷方式；命令行可用 `ditto build/Siphon.app /Applications/Siphon.app`（`ditto` 会保留代码签名与扩展属性）。

`verify.sh` 共 5 组：编译、MD4/eD2K 官方向量（14 项）、HLS/DASH 解析（21 项）、并发有序落盘端到端、以及**真实 aria2 进程 + JSON-RPC 下载 + 字节校验**（未安装 aria2c 时自动跳过）。

也可直接调试运行（需已在 `Resources/` 或 `~/Library/Application Support/Siphon/` 放置 `aria2c`）：

```bash
swift run Siphon
```

`aria2c` 查找顺序：① App Bundle `Contents/Resources/aria2c` → ② `~/Library/Application Support/Siphon/aria2c` → ③ `PATH` 中查找（Apple Silicon 为 `/opt/homebrew/bin`，Intel 为 `/usr/local/bin`）→ ④ 常见绝对路径。可用 `ARIA2C=/path/to/aria2c ./scripts/build-app.sh` 指定。

**打包脚本已处理的分发细节**（已实测）：
- Homebrew 的 `aria2c` 动态链接 6 个 `/opt/homebrew/opt/*/lib/*.dylib`。`build-app.sh` 会把这些库连同传递依赖复制进 `Contents/Frameworks/`，用 `install_name_tool` 改写为 `@executable_path/../Frameworks/`，产物在无 Homebrew 的机器上也能运行。
- 改写 Mach-O 会使原代码签名失效（内核会以 SIGKILL/137 结束进程），脚本对每个嵌套二进制**逐个重签**后再签整个 bundle，并做 `codesign --verify --deep --strict` 校验。
- 当前实测产物约 **14 MB**（主程序 2.1 MB + 图标 1.7 MB + aria2c 3.2 MB + 依赖库），arm64、adhoc 签名，含 `Contents/Resources/AppIcon.icns`。

> 跨架构分发：当前为 arm64。若需通用二进制，用 `lipo -create` 合成 arm64 + x86_64 的 aria2c 及其 dylib（注意 OpenSSL 等库的架构也要匹配），或分别出两个架构的包。正式发布还需 Developer ID 签名 + 公证 + Hardened Runtime。

---

## 4. 目录结构

```
Sources/Siphon/
  SiphonApp.swift              @main 入口，单窗口 Window + Settings scene
  Models/                         协议枚举、任务、进度、状态
  Engines/
    Engine.swift                  统一引擎协议 + 主线程回调协议
    Aria2/                       进程引导、JSON-RPC 客户端、GID 映射与轮询
    Shared/SegmentAssembler.swift  HLS/DASH 共用的并发分段装配器
    HLS/                         m3u8 解析 + AES-128 解密 + TS 输出
    DASH/                        MPD 解析 + 初始化段/媒体段
    ED2K/                        MD4、eD2K 哈希、链接解析、传输后端抽象
  Managers/
    DownloadStore.swift          任务路由、状态聚合、持久化（主数据源）
    QueueManager.swift           命名队列、并发/顺序模式、下载时段窗口
    SpeedLimitController.swift   令牌桶（原生引擎）+ aria2 全局限速转发
    ClipboardMonitor.swift       剪贴板链接捕获
  BrowserExtension/              本地 HTTP 控制接口（NWListener, 127.0.0.1:17801）
  Views/
    Glass.swift                   Liquid Glass 自适应组件（26+ 玻璃 / 14–15 材质回退）
    ...                          NavigationSplitView / 列表 / 检查器 / 设置 / 表单
Resources/
  UI-Preview.png                 真实窗口截图（macOS 27.2，深色模式）
  AppIcon.icns                   打包进 .app 的图标（Info.plist 以 CFBundleIconFile 引用）
  AppIcon-1024.png               1024 不透明主图（App Store 规格，无 alpha 通道）
  AppIcon-Preview.png            圆角 + 阴影的访达效果预览
  AppIcon.iconset/               10 个按原生分辨率渲染的 PNG
  Assets.xcassets/AppIcon.appiconset/   Xcode 可直接使用的 asset catalog
  Info.plist                     URL scheme (magnet/ed2k)、文档类型、最低系统版本
  BrowserExtension/              Manifest V3 扩展示例
scripts/
  build-app.sh                   release 编译 + .app 组装 + dylib 重链接 + 重签名
  make-dmg.sh                    可拖拽安装的 DMG（含挂载后签名校验）
  make-icon.sh / MakeIcon.swift  矢量图标生成器
  verify.sh                      5 组可复现验证
Tests/                           向量、解析与端到端测试
```

---

## 5. eD2K：已完成什么、还差什么

**已实现且经测试验证**：纯 Swift MD4（RFC 1320，7/7 官方向量通过）、eD2K 分块哈希（9,728,000 字节分块）、流式哈希、`ed2k://` 链接解析（文件名/大小/哈希/sources）、下载后哈希校验、以及 `ED2KBackend` 传输抽象。

**未实现**：真正的 P2P 传输。完整 eD2K 客户端需要服务器登录与 ID 分配、按哈希搜索、源交换（server ↔ peer）、peer 握手、180 KiB 分片请求、信用系统，以及 Kad DHT 找源。这属于独立内核，不可能在 UI 脚手架里"顺手"正确实现。`ED2KEngine` 默认使用 `UnavailableED2KBackend`，会明确报错并说明原因，**不会伪装成下载成功**。

接入路径（任选其一，实现 `ED2KBackend` 协议即可，UI 与任务层无需改动）：

1. **libed2k**（推荐）：C++ 库，提供 ed2k session / transfer。用 Objective-C++ 桥接或 C ABI 包装，映射 `connect()` / `download(_:destination:onProgress:)` / `cancel(fileHashHex:)`。
2. **aMule 守护进程**：以 `amulecmd` 或 EC 协议驱动，Swift 侧做进程与协议适配。
3. **自研 Kad/ED2K 栈**：工作量最大，仅在需要完全自持时考虑。

可参考同工作区 `FluxDown-main/native/engine` 的 eD2K 实现（Rust，AGPL-3.0）了解协议分层；若借鉴其代码需注意 AGPL 的传染性。

---

## 6. HLS / DASH 的已知边界

- **HLS**：输出为按序拼接的 MPEG-TS，覆盖绝大多数场景。fMP4 分片（`EXT-X-MAP`）与 CMAF 需要重封装。
- **DASH**：输出为 `init + segments` 的 fMP4 字节流，可被支持 fragmented MP4 的播放器读取；生成通用单文件 MP4 需 `ffmpeg -i in.mp4 -c copy out.mp4`。
- **DRM**（Widevine / FairPlay / ClearKey 等）不在范围内。
- **直播流**（无 `EXT-X-ENDLIST` / 动态 MPD）目前按快照处理；持续录制需扩展为轮询播放列表。
- 若捆绑了 `ffmpeg`，可在落盘后加一步重封装以获得最佳兼容性。

---

## 7. 液态玻璃 UI（macOS 26+）

界面按 Apple 的 Liquid Glass 设计语言重写，核心原则是**玻璃只属于浮层**：

| 规则 | 落地 |
|---|---|
| 玻璃不放在内容背后 | 任务列表、正文、进度条保持不透明；工具栏与边栏由系统自动玻璃化 |
| 相邻玻璃共享一个透镜系统 | 底部悬浮命令条用 `GlassEffectContainer`（封装为 `GlassGroup`）统一包裹状态胶囊、扩展按钮与快捷操作 |
| 交互有折射反馈 | 可点元素用 `.interactive()`，按压/悬停由系统渲染高光与缩放 |
| 强调色克制 | 仅「开始下载」用 `.tint()`；中性面板 `.regular`，小型图标按钮 `.clear` |
| 形变而非弹出 | `glassEffectID` + `Namespace` + `.glassEffectTransition(.matchedGeometry)`，展开快捷操作时玻璃相互融合 |
| 滚动边缘柔化 | `.scrollEdgeEffectStyle(.soft, for: .top)`，列表在半透明栏下渐隐 |
| 微小元素不用玻璃 | 协议徽章保留彩色胶囊，避免失去对比度 |

使用位置：底部悬浮命令条（引擎状态 / 速度 / 恢复全部 / 清理已完成）、任务行圆形控制按钮、详情列浮动信息卡、边栏底部下载位置卡、新建任务表单的头部身份卡与底部按钮组、设置中的引擎状态卡 / 快速限速按钮组 / 关于卡。

**兼容性**：`Package.swift` 仍以 macOS 14 为部署目标。所有 macOS 26 API 都收敛在 `Sources/Siphon/Views/Glass.swift` 的 `if #available(macOS 26.0, *)` 分支里；14/15 自动回退到 `Material` 与 `.bordered` 按钮，单一二进制覆盖两代外观。26.1+ 的 `.glass(_:)` 只用于主按钮的强调色。

**单窗口**：入口用 `Window` 而非 `WindowGroup`。否则每打开一个 `magnet:` / `ed2k:` 链接都会新建窗口（半透明列叠在一起），且默认的「新建窗口」菜单项会与 ⌘N「新建下载」冲突。

其余 HIG 要点：三栏 `NavigationSplitView`、原生工具栏与 `Settings` scene（⌘,）、分组 `Form` / `LabeledContent`、语义色与 SF Symbols、`.help` 提示、系统文件选择器与访达跳转、浅色/深色与辅助功能。

> 实测环境 macOS 27.2：已用真实窗口截图验证玻璃渲染、贴底命令条不遮挡内容、单窗口无叠影、列表无空占位行。图标仍是标准 macOS 26 兼容 `.icns`（系统自动套圆角）；Apple 的分层玻璃图标需 Icon Composer 生成 `.icon`，本机无该工具，故未包含。

---

## 8. 本地控制接口

设置 → 集成 → 开启后监听 `127.0.0.1:17801`：

```bash
curl -X POST http://127.0.0.1:17801/add \
     -H 'Content-Type: application/json' \
     -d '{"url":"https://example.com/file.zip"}'

curl http://127.0.0.1:17801/ping
```

`Resources/BrowserExtension/` 提供可直接「加载已解压的扩展程序」的 Manifest V3 示例。仅绑定回环地址，不监听公网。

---

## 9. 后续路线建议

1. 接入 `ED2KBackend`（libed2k）以完成 eD2K 传输闭环
2. 增加 `ffmpeg` 重封装管线，统一 HLS/DASH 输出为标准 MP4
3. aria2 由 HTTP 轮询改为 WebSocket 通知，降低延迟
4. 任务持久化从 UserDefaults 迁到 SQLite（WAL），支持崩溃恢复与段级续传记录
5. 沙盒 + Hardened Runtime + Developer ID 签名与公证
6. 增加 BT 文件选择、Tracker 管理、RSS 订阅与下载完成脚本

---

## 10. 应用图标

`scripts/MakeIcon.swift` 是唯一的矢量源（CoreGraphics），`./scripts/make-icon.sh` 生成全部产物。设计遵循 macOS Big Sur+ 应用图标规范：

- **方形、不透明、不自带圆角**：由系统统一套用连续曲率圆角遮罩；已用 `NSWorkspace` 解析 `Siphon.app` 实测，系统渲染出的图标自动带圆角且无裁切
- **主体位于安全区**：单一白色圆润下载符号（箭头 + 落点横条），四周留白约 20%，不含任何文字
- **层次克制**：青蓝 → 靛蓝 → 紫的对角渐变、左上柔光、顶部玻璃高光、极淡的斜向流线（呼应「虹吸」），符号一次柔和投影
- **每个尺寸独立渲染**：16 / 32 / 128 / 256 / 512 及各自 @2x 共 10 张，而非从 1024 缩放；`<64px` 自动简化（去掉托盘与阴影、加粗笔画、纯白主体），菜单栏与列表视图下仍可辨识
- **主图无 alpha 通道**：`AppIcon-1024.png` 由纯 `CGContext` 输出 RGB；`.icns` 经 `iconutil` 生成并已往返校验 10 个尺寸齐全

除图标资源外，仓库还附带 `Resources/Assets.xcassets/AppIcon.appiconset/`，可直接用 Xcode 打开。

> macOS 26 的**分层玻璃图标**需要 Apple Icon Composer 产出的 `.icon` bundle（含玻璃层与 Clear / Dark / Tinted 变体）。当前交付的是标准不透明 `.icns`，系统会自动套用圆角；本机未安装 Icon Composer CLI，因此没有生成 `.icon`。这与 §7 的界面液态玻璃是两件事。

---

## 11. 许可证与第三方

本仓库 Swift 源码采用 **MIT**（见 [LICENSE](LICENSE)）。aria2 为 **GPLv2**，**不随本仓库分发**：Siphon 以独立进程 + JSON-RPC 调用 `aria2c`，不链接 `libaria2`、不合并二进制，因此应用自身不必 GPL 化。

`build-app.sh` 会从本机 Homebrew 复制 `aria2c` 及其依赖库到 `.app` 中；**再分发该 `.app` 时需自行履行 aria2 的 GPLv2 义务**（提供对应源码，或仅分发上游未修改二进制）。可选的 `ffmpeg` 同理，其许可证取决于构建配置。若将来改为链接 `libaria2`，需重新评估合规义务。

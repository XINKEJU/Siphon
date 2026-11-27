import Foundation

/// MDM routes every user-visible string through `crate::i18n`. Siphon's
/// existing views still contain literal Chinese strings; all newly written
/// MDM-aligned views use this catalog instead. The catalog is intentionally a
/// plain key→text map so `tools/i18n/extract.py` can regenerate `en.tsv` and
/// translators can work without Swift tooling.
public final class MDMI18n {
    public static let shared = MDMI18n()

    /// 87 BCP-47 languages, matching MDM's coverage. The first 12 are the
    /// priority-review set; the rest are machine-translated and tracked by
    /// `status` in the per-language manifest.
    public static let availableLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("pt-BR", "Português (Brasil)"), ("ru", "Русский"),
        ("ar", "العربية"), ("tr", "Türkçe"),
        ("it", "Italiano"), ("nl", "Nederlands"), ("pl", "Polski"), ("sv", "Svenska"),
        ("da", "Dansk"), ("fi", "Suomi"), ("no", "Norsk"), ("cs", "Čeština"),
        ("hu", "Magyar"), ("ro", "Română"), ("el", "Ελληνικά"), ("he", "עברית"),
        ("th", "ไทย"), ("vi", "Tiếng Việt"), ("id", "Bahasa Indonesia"), ("ms", "Bahasa Melayu"),
        ("uk", "Українська"), ("bg", "Български"), ("hr", "Hrvatski"), ("sr", "Српски"),
        ("sk", "Slovenčina"), ("sl", "Slovenščina"), ("et", "Eesti"), ("lv", "Latviešu"),
        ("lt", "Lietuvių"), ("fa", "فارسی"), ("hi", "हिन्दी"), ("bn", "বাংলা"),
        ("ta", "தமிழ்"), ("te", "తెలుగు"), ("ml", "മലയാളം"), ("mr", "मराठी"),
        ("gu", "ગુજરાતી"), ("pa", "ਪੰਜਾਬੀ"), ("kn", "ಕನ್ನಡ"), ("ur", "اردو"),
        ("ne", "नेपाली"), ("si", "සිංහල"), ("my", "မြန်မာ"), ("km", "ខ្មែរ"),
        ("lo", "ລາວ"), ("ka", "ქართული"), ("am", "አማርኛ"), ("sw", "Kiswahili"),
        ("zu", "isiZulu"), ("xh", "isiXhosa"), ("af", "Afrikaans"), ("sq", "Shqip"),
        ("hy", "Հայերեն"), ("az", "Azərbaycan"), ("eu", "Euskara"), ("be", "Беларуская"),
        ("bs", "Bosanski"), ("ca", "Català"), ("cy", "Cymraeg"), ("eo", "Esperanto"),
        ("fo", "Føroyskt"), ("gl", "Galego"), ("is", "Íslenska"), ("ga", "Gaeilge"),
        ("kk", "Қазақ"), ("ky", "Кыргызча"), ("lb", "Lëtzebuergesch"), ("mk", "Македонски"),
        ("mt", "Malti"), ("mn", "Монгол"), ("oc", "Occitan"), ("se", "Davvisámegiella"),
        ("tl", "Tagalog"), ("br", "Brezhoneg"), ("co", "Corsu"), ("gd", "Gàidhlig"),
        ("fy", "Frysk"), ("yi", "ייִדיש"), ("ps", "پښتو"), ("sd", "سنڌي"),
        ("ug", "ئۇيغۇرچە"), ("bo", "བོད་སྐད་"), ("dz", "རྫོང་ཁ"), ("iu", "ᐃᓄᒃᑎᑐᑦ"),
    ]

    /// Languages whose layout direction is right-to-left.
    public static let rtlLanguages: Set<String> = ["ar", "he", "fa", "ur", "ug", "ps", "sd", "yi"]

    public var language: String {
        get { UserDefaults.standard.string(forKey: "Siphon.mdm.language") ?? "zh-Hans" }
        set {
            UserDefaults.standard.set(newValue, forKey: "Siphon.mdm.language")
            NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        }
    }

    public static let languageDidChange = Notification.Name("SiphonMDMLanguageDidChange")

    private var catalogs: [String: [String: String]] = [:]
    private let bundle: Bundle

    private init() {
        bundle = Bundle(for: BundleToken.self)
        loadEmbeddedCatalogs()
        loadTSVCatalogs()
    }

    private func loadEmbeddedCatalogs() {
        // Fallback embedded English so the app never shows raw keys when the
        // resource bundle is missing (e.g. unit tests compiled with swiftc).
        catalogs["en"] = English
        catalogs["zh-Hans"] = ChineseSimplified
        catalogs["zh-Hant"] = ChineseTraditional
    }

    private func loadTSVCatalogs() {
        guard let resourceURL = bundle.resourceURL else { return }
        let i18nURL = resourceURL.appendingPathComponent("i18n")
        guard let files = try? FileManager.default.contentsOfDirectory(at: i18nURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "tsv" {
            let code = file.deletingPathExtension().lastPathComponent
            if let dict = Self.parseTSV(at: file) {
                catalogs[code] = dict
            }
        }
    }

    static func parseTSV(at url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            result[parts[0]] = parts[1]
        }
        return result
    }

    /// Lookup with deterministic fallback: requested language → English → key.
    /// Format arguments use the standard `%@` style via String(format:).
    public static func t(_ key: String, _ args: CVarArg...) -> String {
        let value = shared.catalogs[shared.language]?[key]
            ?? shared.catalogs["en"]?[key]
            ?? key
        guard !args.isEmpty else { return value }
        return String(format: value, arguments: args)
    }

    public func localize(_ key: String, _ args: CVarArg...) -> String {
        let value = catalogs[language]?[key] ?? catalogs["en"]?[key] ?? key
        guard !args.isEmpty else { return value }
        return String(format: value, arguments: args)
    }

    /// Every key in the English catalog, sorted — used by the extractor and
    /// by the options page that reports translation completeness.
    public static var allKeys: [String] { Array(English.keys).sorted() }

    public var isRTL: Bool { Self.rtlLanguages.contains(language) }
}

private final class BundleToken {}

private let English: [String: String] = [
    "app.name": "Siphon",
    "menu.tasks": "Tasks",
    "menu.file": "File",
    "menu.downloads": "Downloads",
    "menu.view": "View",
    "menu.help": "Help",
    "menu.addURL": "Add URL…",
    "menu.downloadLater": "Download Later…",
    "menu.linkGrabber": "Link grabber…",
    "menu.batch": "Batch…",
    "menu.find": "Find…",
    "menu.scheduler": "Scheduler…",
    "menu.options": "Options…",
    "menu.properties": "Properties…",
    "menu.verifyChecksum": "Verify checksum…",
    "menu.pauseSelected": "Pause selected",
    "menu.resumeSelected": "Resume selected",
    "menu.copySelectedLinks": "Copy selected links",
    "menu.deleteSelected": "Delete selected…",
    "menu.clearSelection": "Clear selection",
    "menu.showInspector": "Preview pane",
    "menu.showPopup": "Download popup",
    "menu.resumeAll": "Start all",
    "menu.pauseAll": "Pause all",
    "category.all": "All Downloads",
    "category.unfinished": "Unfinished",
    "category.finished": "Finished",
    "category.queues": "Queues",
    "category.general": "General",
    "category.compressed": "Compressed",
    "category.documents": "Documents",
    "category.music": "Music",
    "category.programs": "Programs",
    "category.video": "Video",
    "category.torrents": "Torrents",
    "queue.main": "Main download queue",
    "queue.synchronization": "Synchronization queue",
    "status.queued": "Queued",
    "status.downloading": "Downloading",
    "status.stopped": "Stopped",
    "status.complete": "Complete",
    "status.error": "Error",
    "column.fileName": "File Name",
    "column.queue": "Q",
    "column.size": "Size",
    "column.status": "Status",
    "column.timeLeft": "Time left",
    "column.rate": "Transfer rate",
    "column.lastTry": "Last Try",
    "column.description": "Description",
    "column.added": "Added",
    "column.source": "Source",
    "column.peers": "Peers",
    "column.shareRatio": "Share ratio",
    "column.uploadSpeed": "Upload speed",
    "column.saveTo": "Save To",
    "column.details": "Details (Peers / Ratio / Upload / Save To)",
    "progress.status": "Status",
    "progress.limiter": "Limiter",
    "progress.completion": "Completion",
    "progress.segments": "Segments",
    "progress.connections": "Connections",
    "progress.resumeCapability": "Resume capability",
    "progress.stopAndKeep": "Stop and keep",
    "options.general": "General",
    "options.fileTypes": "File types",
    "options.saveTo": "Save to",
    "options.downloads": "Downloads",
    "options.connection": "Connection",
    "options.remote": "Remote",
    "options.proxy": "Proxy",
    "options.socks": "Socks",
    "options.sitesLogins": "Sites Logins",
    "options.accounts": "Accounts",
    "options.sounds": "Sounds",
    "options.regional": "Regional",
    "options.archives": "Archives",
    "theme.highContrast": "High contrast",
    "dialog.addURL": "Download File Info",
    "dialog.startDownload": "Start Download",
    "dialog.downloadLater": "Download Later",
    "dialog.saveTo": "Save to:",
    "dialog.category": "Category:",
    "dialog.description": "Description:",
    "dialog.linkGrabber": "Link grabber",
    "dialog.scheduler": "Scheduler",
    "dialog.batch": "Batch download",
    "dialog.find": "Find",
    "dialog.properties": "Properties",
    "dialog.verifyChecksum": "Verify checksum",
    "action.cancel": "Cancel",
    "action.close": "Close",
    "action.remove": "Remove from list",
    "action.delete": "Delete file and remove",
    "action.copyLink": "Copy link",
    "action.open": "Open",
    "action.reveal": "Open folder",
    "progress.window": "Download progress",
    "torrent.files": "Files",
    "torrent.peers": "Peers",
    "torrent.trackers": "Trackers",
    "torrent.pieces": "Pieces",
    "torrent.general": "General",
    "torrent.transfer": "Transfer",
    "torrent.name": "Name",
    "torrent.infoHash": "Info hash",
    "torrent.size": "Size",
    "torrent.downloaded": "Downloaded",
    "torrent.uploaded": "Uploaded",
    "torrent.shareRatio": "Share ratio",
    "torrent.downSpeed": "Down speed",
    "torrent.upSpeed": "Up speed",
    "torrent.seeders": "Seeders / Leechers",
    "torrent.options": "Options",
    "torrent.sequential": "Sequential download",
    "torrent.recheck": "Recheck",
    "torrent.metadataPending": "Metadata not resolved yet.",
    "torrent.noPeers": "No peers connected.",
    "torrent.noTrackers": "No trackers.",
    "torrent.noPieces": "No piece data.",
    "torrent.connected": "%@ connected",
    "torrent.selectedCount": "%1$@/%2$@ selected",
    "torrent.perTaskUploadNote": "Per-task upload limit requires the librqbit helper."
]

private let ChineseSimplified: [String: String] = [
    "app.name": "Siphon",
    "menu.tasks": "任务",
    "menu.file": "文件",
    "menu.downloads": "下载",
    "menu.view": "显示",
    "menu.help": "帮助",
    "menu.addURL": "添加 URL…",
    "menu.downloadLater": "稍后下载…",
    "menu.linkGrabber": "链接抓取器…",
    "menu.batch": "批量下载…",
    "menu.find": "查找…",
    "menu.scheduler": "计划任务…",
    "menu.options": "选项…",
    "menu.properties": "属性…",
    "menu.verifyChecksum": "校验校验和…",
    "menu.pauseSelected": "暂停所选",
    "menu.resumeSelected": "继续所选",
    "menu.copySelectedLinks": "拷贝所选链接",
    "menu.deleteSelected": "删除所选…",
    "menu.clearSelection": "取消选择",
    "menu.showInspector": "预览窗格",
    "menu.showPopup": "下载弹窗",
    "menu.resumeAll": "恢复全部",
    "menu.pauseAll": "全部暂停",
    "category.all": "所有下载",
    "category.unfinished": "未完成",
    "category.finished": "已完成",
    "category.queues": "队列",
    "category.general": "常规",
    "category.compressed": "压缩文件",
    "category.documents": "文档",
    "category.music": "音乐",
    "category.programs": "程序",
    "category.video": "视频",
    "category.torrents": "种子",
    "queue.main": "主下载队列",
    "queue.synchronization": "同步队列",
    "status.queued": "排队中",
    "status.downloading": "下载中",
    "status.stopped": "已停止",
    "status.complete": "已完成",
    "status.error": "出错",
    "column.fileName": "文件名",
    "column.queue": "队列",
    "column.size": "大小",
    "column.status": "状态",
    "column.timeLeft": "剩余时间",
    "column.rate": "传输速率",
    "column.lastTry": "上次尝试",
    "column.description": "描述",
    "column.added": "添加时间",
    "column.source": "来源",
    "column.peers": "对等端",
    "column.shareRatio": "分享率",
    "column.uploadSpeed": "上传速度",
    "column.saveTo": "保存位置",
    "column.details": "详情（对等端 / 分享率 / 上传 / 位置）",
    "progress.status": "状态",
    "progress.limiter": "限速器",
    "progress.completion": "完成后",
    "progress.segments": "分段",
    "progress.connections": "连接",
    "progress.resumeCapability": "可续传",
    "progress.stopAndKeep": "停止并保留",
    "options.general": "常规",
    "options.fileTypes": "文件类型",
    "options.saveTo": "保存位置",
    "options.downloads": "下载",
    "options.connection": "连接",
    "options.remote": "远程",
    "options.proxy": "代理",
    "options.socks": "Socks",
    "options.sitesLogins": "站点登录",
    "options.accounts": "账户",
    "options.sounds": "声音",
    "options.regional": "区域",
    "options.archives": "归档",
    "theme.highContrast": "高对比度",
    "dialog.addURL": "下载文件信息",
    "dialog.startDownload": "开始下载",
    "dialog.downloadLater": "稍后下载",
    "dialog.saveTo": "保存位置：",
    "dialog.category": "分类：",
    "dialog.description": "描述：",
    "dialog.linkGrabber": "链接抓取器",
    "dialog.scheduler": "计划任务",
    "dialog.batch": "批量下载",
    "dialog.find": "查找",
    "dialog.properties": "属性",
    "dialog.verifyChecksum": "校验校验和",
    "action.cancel": "取消",
    "action.close": "关闭",
    "action.remove": "从列表移除",
    "action.delete": "删除文件并移除",
    "action.copyLink": "复制链接",
    "action.open": "打开",
    "action.reveal": "打开文件夹",
    "progress.window": "下载进度",
    "torrent.files": "文件",
    "torrent.peers": "对等端",
    "torrent.trackers": "追踪器",
    "torrent.pieces": "区块",
    "torrent.general": "常规",
    "torrent.transfer": "传输",
    "torrent.name": "名称",
    "torrent.infoHash": "信息哈希",
    "torrent.size": "大小",
    "torrent.downloaded": "已下载",
    "torrent.uploaded": "已上传",
    "torrent.shareRatio": "分享率",
    "torrent.downSpeed": "下载速度",
    "torrent.upSpeed": "上传速度",
    "torrent.seeders": "种子 / 下载者",
    "torrent.options": "选项",
    "torrent.sequential": "顺序下载",
    "torrent.recheck": "重新校验",
    "torrent.metadataPending": "元数据尚未解析。",
    "torrent.noPeers": "暂无连接的对等端。",
    "torrent.noTrackers": "暂无追踪器。",
    "torrent.noPieces": "暂无区块数据。",
    "torrent.connected": "已连接 %@",
    "torrent.selectedCount": "已选 %1$@/%2$@",
    "torrent.perTaskUploadNote": "单任务上传限速需要 librqbit 辅助进程。"
]

private let ChineseTraditional: [String: String] = [
    "app.name": "Siphon",
    "menu.tasks": "任務",
    "menu.file": "檔案",
    "menu.downloads": "下載",
    "menu.view": "顯示",
    "menu.help": "說明",
    "menu.addURL": "新增 URL…",
    "menu.downloadLater": "稍後下載…",
    "menu.linkGrabber": "連結擷取器…",
    "menu.batch": "批次下載…",
    "menu.find": "尋找…",
    "menu.scheduler": "排程…",
    "menu.options": "選項…",
    "menu.properties": "屬性…",
    "menu.verifyChecksum": "驗證校驗和…",
    "menu.pauseSelected": "暫停所選",
    "menu.resumeSelected": "繼續所選",
    "menu.copySelectedLinks": "拷貝所選連結",
    "menu.deleteSelected": "刪除所選…",
    "menu.clearSelection": "取消選擇",
    "menu.showInspector": "預覽窗格",
    "menu.showPopup": "下載彈窗",
    "menu.resumeAll": "恢復全部",
    "menu.pauseAll": "全部暫停",
    "category.all": "所有下載",
    "category.unfinished": "未完成",
    "category.finished": "已完成",
    "category.queues": "佇列",
    "category.general": "一般",
    "category.compressed": "壓縮檔",
    "category.documents": "文件",
    "category.music": "音樂",
    "category.programs": "程式",
    "category.video": "影片",
    "category.torrents": "種子",
    "queue.main": "主下載佇列",
    "queue.synchronization": "同步佇列",
    "status.queued": "排隊中",
    "status.downloading": "下載中",
    "status.stopped": "已停止",
    "status.complete": "已完成",
    "status.error": "錯誤",
    "column.fileName": "檔案名稱",
    "column.queue": "佇列",
    "column.size": "大小",
    "column.status": "狀態",
    "column.timeLeft": "剩餘時間",
    "column.rate": "傳輸速率",
    "column.lastTry": "上次嘗試",
    "column.description": "描述",
    "column.added": "加入時間",
    "column.source": "來源",
    "column.peers": "對等端",
    "column.shareRatio": "分享率",
    "column.uploadSpeed": "上傳速度",
    "column.saveTo": "儲存位置",
    "column.details": "詳情（對等端 / 分享率 / 上傳 / 位置）",
    "progress.status": "狀態",
    "progress.limiter": "限速器",
    "progress.completion": "完成後",
    "progress.segments": "分段",
    "progress.connections": "連線",
    "progress.resumeCapability": "可續傳",
    "progress.stopAndKeep": "停止並保留",
    "options.general": "一般",
    "options.fileTypes": "檔案類型",
    "options.saveTo": "儲存位置",
    "options.downloads": "下載",
    "options.connection": "連線",
    "options.remote": "遠端",
    "options.proxy": "代理",
    "options.socks": "Socks",
    "options.sitesLogins": "網站登入",
    "options.accounts": "帳戶",
    "options.sounds": "音效",
    "options.regional": "區域",
    "options.archives": "封存",
    "theme.highContrast": "高對比度",
    "dialog.addURL": "下載檔案資訊",
    "dialog.startDownload": "開始下載",
    "dialog.downloadLater": "稍後下載",
    "dialog.saveTo": "儲存位置：",
    "dialog.category": "分類：",
    "dialog.description": "描述：",
    "dialog.linkGrabber": "連結擷取器",
    "dialog.scheduler": "排程",
    "dialog.batch": "批次下載",
    "dialog.find": "尋找",
    "dialog.properties": "屬性",
    "dialog.verifyChecksum": "驗證校驗和",
    "action.cancel": "取消",
    "action.close": "關閉",
    "action.remove": "從列表移除",
    "action.delete": "刪除檔案並移除",
    "action.copyLink": "複製連結",
    "action.open": "開啟",
    "action.reveal": "打開資料夾",
    "progress.window": "下載進度",
    "torrent.files": "檔案",
    "torrent.peers": "對等端",
    "torrent.trackers": "追蹤器",
    "torrent.pieces": "區塊",
    "torrent.general": "一般",
    "torrent.transfer": "傳輸",
    "torrent.name": "名稱",
    "torrent.infoHash": "資訊雜湊",
    "torrent.size": "大小",
    "torrent.downloaded": "已下載",
    "torrent.uploaded": "已上傳",
    "torrent.shareRatio": "分享率",
    "torrent.downSpeed": "下載速度",
    "torrent.upSpeed": "上傳速度",
    "torrent.seeders": "種子 / 下載者",
    "torrent.options": "選項",
    "torrent.sequential": "順序下載",
    "torrent.recheck": "重新校驗",
    "torrent.metadataPending": "中繼資料尚未解析。",
    "torrent.noPeers": "尚無連線的對等端。",
    "torrent.noTrackers": "尚無追蹤器。",
    "torrent.noPieces": "尚無區塊資料。",
    "torrent.connected": "已連線 %@",
    "torrent.selectedCount": "已選 %1$@/%2$@",
    "torrent.perTaskUploadNote": "單一任務上傳限速需要 librqbit 輔助程序。"
]

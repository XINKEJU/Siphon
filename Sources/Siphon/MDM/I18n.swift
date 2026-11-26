import Foundation

/// MDM routes every user-visible string through `crate::i18n`. Siphon's
/// existing views still contain literal Chinese strings; all newly written
/// MDM-aligned views use this catalog instead. The catalog is intentionally a
/// plain key→text map so `tools/i18n/extract.py` can regenerate `en.tsv` and
/// translators can work without Swift tooling.
public final class MDMI18n {
    public static let shared = MDMI18n()

    public static let availableLanguages: [(code: String, name: String)] = [
        ("zh", "中文"), ("en", "English")
    ]

    public var language: String {
        get { UserDefaults.standard.string(forKey: "Siphon.mdm.language") ?? "zh" }
        set { UserDefaults.standard.set(newValue, forKey: "Siphon.mdm.language") }
    }

    private let catalogs: [String: [String: String]] = [
        "en": English, "zh": Chinese
    ]

    private init() {}

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
}

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
    "action.reveal": "Open folder"
]

private let Chinese: [String: String] = [
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
    "action.reveal": "打开文件夹"
]

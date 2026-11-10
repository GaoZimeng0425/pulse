import Foundation

// MARK: - 应用缓存知识库(p6-cleaner/01)

//
// ~/Library/Caches 一级目录名 → 定档表:**认得出的目录才进清单,认不出不列不碰**
// (ADR-0008;spec 定案 10——"按大小发现、未识别也列"的阈值式留待二期单拍)。
// 名字与档位移植自 purge-app(jithin-sabu/purge-app,MIT License)
// `purge/Resources/explanations.json`(目录名匹配 key / aliases / bundle_ids 的
// 上游语义收编为"规范大小写目录名,字面精确匹配");文案按 Pulse 两档口径中文
// 重写,不是逐字翻译。`Pulse 自定`三条为本机真案(来源不是上游)。
// 表经 `JunkRuleTable.builtin` 变成规则(pattern = Library/Caches/<目录名> 字面),
// 匹配 / 去重 / UI / 历史 / 排除 / 孤儿域收窄(OrphanLeftovers.excludingOverlaps)
// 全部走既有管线——这里只放数据,零新机制。

public enum AppCacheCatalog {
    /// 知识库一条:一个 app / 浏览器,可有多个缓存目录名(不同版本 / 帮手进程)。
    public struct Entry: Sendable, Equatable {
        public let key: String
        /// ~/Library/Caches 下的一级目录名(规范大小写;匹配字面精确、大小写敏感)。
        public let names: [String]
        public let title: String
        public let group: JunkGroup
        public let tier: CleanSafetyTier
        public let rationale: String
        public let source: String
        public let symbolName: String

        public init(
            key: String,
            names: [String],
            title: String,
            group: JunkGroup,
            tier: CleanSafetyTier,
            rationale: String,
            source: String,
            symbolName: String
        ) {
            self.key = key
            self.names = names
            self.title = title
            self.group = group
            self.tier = tier
            self.rationale = rationale
            self.source = source
            self.symbolName = symbolName
        }
    }

    /// 首批清单:浏览器全家 + 常见 app(本机在场与高频优先;com.apple 守护进程
    /// 缓存与长尾 app 留待后续批次持续扩充,加条目即扩,无机制改动)。
    public static let entries: [Entry] = [
        // —— 浏览器(网页缓存,清了重新加载,登录与书签不受影响)——
        Entry(
            key: "arc",
            names: ["Arc", "company.thebrowser.browser"],
            title: "Arc 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Arc 的网页与内核临时文件;清了下次打开网页重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "dia",
            names: ["Dia", "company.thebrowser.dia"],
            title: "Dia 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Dia 的网页与内核临时文件;清了下次打开网页重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "chrome",
            names: ["Google", "Chrome", "com.google.Chrome"],
            title: "Chrome 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Chrome 的网页缓存(Google 目录含其组件缓存);清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "chromium",
            names: ["Chromium", "org.chromium.Chromium"],
            title: "Chromium 缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Chromium 的网页缓存;清了重新加载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "edge",
            names: ["com.microsoft.edgemac", "Microsoft Edge"],
            title: "Edge 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Edge 的网页缓存;清了重新加载,登录与收藏不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "brave",
            names: ["com.brave.Browser", "Brave"],
            title: "Brave 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Brave 的网页缓存;清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "firefox",
            names: ["org.mozilla.firefox", "Firefox"],
            title: "Firefox 缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Firefox 的网页缓存;清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "opera",
            names: ["com.operasoftware.Opera", "Opera"],
            title: "Opera 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Opera 的网页缓存;清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "zen",
            names: ["Zen", "zen"],
            title: "Zen 浏览器缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Zen 的网页缓存;清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
        Entry(
            key: "safari",
            names: ["com.apple.Safari", "Safari"],
            title: "Safari 缓存",
            group: .browserCache,
            tier: .safe,
            rationale: "Safari 的网页缓存;清了重新加载,登录与书签不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "safari"
        ),
        // —— 常见 app ——
        Entry(
            key: "cloudkit",
            names: ["CloudKit"],
            title: "CloudKit 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统 iCloud 联动的本地缓存;删除不影响云端数据,但会触发重新同步,库大时要等一阵。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "icloud"
        ),
        Entry(
            key: "geoservices",
            names: ["GeoServices"],
            title: "地图瓦片缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果地图的离线瓦片;清了要看地图时重新下载,离线场景会变慢。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "map"
        ),
        Entry(
            key: "slack",
            names: ["Slack", "com.tinyspeck.slackmacgap"],
            title: "Slack 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "消息与文件缓存;聊天记录在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "message"
        ),
        Entry(
            key: "discord",
            names: ["Discord", "com.hnc.Discord"],
            title: "Discord 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "消息媒体缓存;下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "message"
        ),
        Entry(
            key: "zoom",
            names: ["zoom.us", "us.zoom.xos"],
            title: "Zoom 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "会议客户端缓存;删除后重新生成,会议录制不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "video"
        ),
        Entry(
            key: "telegram",
            names: ["Telegram", "ru.keepcoder.Telegram"],
            title: "Telegram 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "聊天媒体缓存,服务器留有副本(秘密聊天除外——其媒体只在本机)。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "message"
        ),
        Entry(
            key: "whatsapp",
            names: ["WhatsApp", "net.whatsapp.WhatsApp"],
            title: "WhatsApp 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "媒体与预览缓存;聊天备份不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "message"
        ),
        Entry(
            key: "notion",
            names: ["Notion", "notion.id"],
            title: "Notion 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "页面缓存;内容在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc"
        ),
        Entry(
            key: "spotify",
            names: ["Spotify", "com.spotify.client"],
            title: "Spotify 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "播放缓冲;清了重新缓冲,已下载的离线歌曲在别的目录不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "music.note"
        ),
        Entry(
            key: "figma",
            names: ["Figma", "com.figma.Desktop"],
            title: "Figma 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "设计文件缓存;文档在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "square.on.circle"
        ),
        Entry(
            key: "linear",
            names: ["Linear", "com.linear"],
            title: "Linear 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "议题数据缓存;内容在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc"
        ),
        Entry(
            key: "raycast",
            names: ["Raycast", "com.raycast.macos"],
            title: "Raycast 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "启动器缓存;删除后自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "wand.and.stars"
        ),
        Entry(
            key: "alfred",
            names: ["Alfred", "com.runningwithcrayons.Alfred"],
            title: "Alfred 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "启动器缓存;删除后自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "wand.and.stars"
        ),
        Entry(
            key: "claude",
            names: ["Claude", "com.anthropic.claudefordesktop"],
            title: "Claude 桌面版缓存",
            group: .appCache,
            tier: .safe,
            rationale: "桌面客户端缓存;对话在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "chatgpt",
            names: ["ChatGPT", "com.openai.chat"],
            title: "ChatGPT 桌面版缓存",
            group: .appCache,
            tier: .safe,
            rationale: "桌面客户端缓存;对话在云端,下次打开重新拉取。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "iterm2",
            names: ["iTerm2", "com.googlecode.iterm2"],
            title: "iTerm2 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "终端缓存;删除后自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "terminal"
        ),
        Entry(
            key: "warp",
            names: ["Warp", "dev.warp.Warp-Stable"],
            title: "Warp 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "终端缓存;删除后自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "terminal"
        ),
        Entry(
            key: "ghostty",
            names: ["Ghostty", "com.mitchellh.ghostty"],
            title: "Ghostty 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "终端缓存;删除后自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "terminal"
        ),
        Entry(
            key: "msAutoUpdate",
            names: ["com.microsoft.autoupdate.fba", "Microsoft AutoUpdate"],
            title: "Microsoft 自动更新缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Office 更新器的下载缓存;清了下次更新重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "edgeUpdater",
            names: ["com.microsoft.EdgeUpdater"],
            title: "Edge 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Edge 更新器的下载缓存;清了下次更新重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "googleUpdater",
            names: ["com.google.Keystone", "com.google.GoogleUpdater"],
            title: "Google 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Google 更新器(Keystone)的下载缓存;清了下次更新重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        // —— Pulse 自定(本机真案,来源非上游)——
        Entry(
            key: "easydict",
            names: ["com.izual.Easydict"],
            title: "Easydict 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "开源翻译器的查询缓存;清了下次查询重新发起。",
            source: JunkRuleTable.pulseCustom,
            symbolName: "character.book.closed"
        ),
        Entry(
            key: "doubaoIme",
            names: ["com.bytedance.inputmethod.doubaoime", "com.bytedance.inputmethod.doubaoime.settings"],
            title: "豆包输入法缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "输入法模型与联想缓存;删除后要重新下载,期间联想与转写可能变慢。",
            source: JunkRuleTable.pulseCustom,
            symbolName: "keyboard"
        ),
        Entry(
            key: "zcodeUpdater",
            names: ["@zcodedesktop-updater"],
            title: "ZCode 更新包缓存",
            group: .appCache,
            tier: .safe,
            rationale: "ZCode 更新器下载的安装包;清了下次更新重新下载。",
            source: JunkRuleTable.pulseCustom,
            symbolName: "arrow.triangle.2.circlepath"
        ),
    ]

    /// 知识库 → 规则:一条 Entry 一条规则(多个目录名 = 多 pattern,同一担保)。
    /// id 前缀 `browser.` / `appcache.`;字面精确匹配保留规范大小写。
    public static let rules: [JunkRule] = entries.map { entry in
        let idPrefix = entry.group == .browserCache ? "browser" : "appcache"
        return JunkRule(
            id: "\(idPrefix).\(entry.key)",
            group: entry.group,
            title: entry.title,
            patterns: entry.names.map { JunkPathPattern(homeRelative: "Library/Caches/\($0)") },
            tier: entry.tier,
            rationale: entry.rationale,
            source: entry.source,
            symbolName: entry.symbolName
        )
    }
}

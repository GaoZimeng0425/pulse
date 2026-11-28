import Foundation

// MARK: - 应用缓存知识库(p6-cleaner/01 建;p7-cleaner/09 自 purge-app 全量搬运)

//
// ~/Library/Caches 一级目录名 → 定档表。本表只决定「认得出的目录」的档位——命中才有
// 资格进「可安全清理」;认不出的目录不经本表,由通用发现(`GenericDiscovery`)兜住,
// 一律「先检查」(ADR-0013 改写 ADR-0008 的「认不出不列不碰」)。
//
// 数据分四摞,档位纪律各不相同:
//   · browsers / apps:浏览器与第三方应用的缓存。认识的归档位:可重建的进「可安全清理」,
//     有可见代价的(要重新同步、重新下载很慢、带着算出来的历史)进「先检查」。
//   · apple:苹果自家的应用与后台服务的缓存,恒「先检查」——这些服务常驻,没有可靠的
//     「在运行」信号;上游把其中不少标成安全,我们一律不自动勾(`AppCacheCatalogTests`
//     钉住)。想放开某一条,是改一处档位的事。
//   · custom:Pulse 自定(本机真案,来源不是上游)。
//
// 出处与许可:目录名、档位、条目的划分移植自 purge-app(jithin-sabu/purge-app,MIT License,
// 可移植)`purge/Resources/explanations.json`(2026-11-28 读取,提交 ceacaf8)。文案按 Pulse
// 两档口径中文重写,不是逐字翻译。上游的匹配不分大小写,这里收编为「规范大小写目录名,
// 字面精确匹配」(本机实测 104 个目录,两种认法结果相同)。
//
// 搬运口径(p7-cleaner/09;逐条的下落在 `AppCacheCatalogPortLedgerTests` 的搬运账本):
//   · 新条目的 key 直接用上游 key(出处即标识);p6 首批的 key 保持不变。
//   · 上游那张表混着应用缓存、开发工具缓存、项目产物三种东西。只有「确实是缓存目录下
//     一级目录名」的才进这里。开发工具与项目产物(Homebrew、VS Code、node_modules、
//     DerivedData 这类)归开发工具规则与票 10。
//   · 上游自己的安全策略「永不列出」的条目(Apple 账号登录类后台服务、钱包、屏幕使用
//     时间、密码管理器…)不搬——照表搬会比上游更松。
//   · 上游登记的应用显示名(如「Affinity Designer」「TablePlus」)只搬证实是缓存目录名的:
//     反域名包名、独造词(撞不上别的软件)。普通英文单词(Sketch、Loom、Fork)没证实的不搬,
//     真有那个目录也由通用发现以「先检查」列出。
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

    /// 浏览器:网页缓存,清了重新加载,登录与书签不受影响。
    static let browsers: [Entry] = [
        // p7-cleaner/09 补的目录名(上游同一条目里登记的)
        Entry(
            key: "arc",
            names: [
                "Arc",
                "company.thebrowser.browser",
                "company.thebrowser.browser.helper",
                "company.thebrowser.Browser",
            ],
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
        // p7-cleaner/09 搬运:上游只在这个目录确实只有缓存形状时才判安全,我们不做形状核对,落「先检查」
        Entry(
            key: "yab",
            names: ["Yab"],
            title: "Yab 浏览器缓存",
            group: .browserCache,
            tier: .checkFirst,
            rationale: "Yab 浏览网页时存下的网页文件与脚本;清了下次访问要重新下载,网页会慢一阵。没法保证这个目录里只有缓存,所以不自动勾,清之前先看一眼。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "globe"
        ),
    ]

    /// 第三方应用(非浏览器)的缓存。
    static let apps: [Entry] = [
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
        // p7-cleaner/09 补的目录名(上游同一条目里登记的)
        Entry(
            key: "figma",
            names: ["Figma", "com.figma.Desktop", "com.figma.agent"],
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
        // p7-cleaner/09 补的目录名(上游同一条目里登记的)
        Entry(
            key: "googleUpdater",
            names: ["com.google.Keystone", "com.google.GoogleUpdater", "com.google.antigravity.ShipIt"],
            title: "Google 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Google 更新器(Keystone)的下载缓存;清了下次更新重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        // —— p7-cleaner/09 搬运 ——
        // —— 更新器 ——
        Entry(
            key: "perplexity-updater",
            names: ["ai.perplexity.CometUpdater", "CometUpdater"],
            title: "Perplexity Comet 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Perplexity Comet 浏览器检查更新时用到的临时文件;清了下次检查更新时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "claude-updater",
            names: ["com.anthropic.claudefordesktop.ShipIt"],
            title: "Claude 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Claude 桌面版更新器留下的安装临时文件;清了下次检查更新时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "todesktop-shipit",
            names: ["com.todesktop.230313mzl4w4u92.ShipIt"],
            title: "Cursor 更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Cursor 的更新器留下的安装临时文件;清了下次检查更新时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "shipit-updater-cache",
            names: ["ShipIt"],
            title: "应用更新器缓存",
            group: .appCache,
            tier: .safe,
            rationale: "用 ShipIt 这类更新器的应用留下的安装临时文件;清了应用下次检查更新时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "google-sdks-events",
            names: ["google-sdks-events"],
            title: "Google SDK 待上报事件",
            group: .appCache,
            tier: .safe,
            rationale: "应用里集成的 Google 开发工具包(登录、统计等)攒着还没上报的使用事件;清了只是丢掉这些统计数据,应用功能不受影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "chart.bar"
        ),
        // —— Adobe 与设计工具 ——
        Entry(
            key: "adobe-media-cache-files",
            names: ["Adobe Media Cache Files"],
            title: "Adobe 媒体缓存文件",
            group: .appCache,
            tier: .safe,
            rationale: "Premiere Pro 与 After Effects 渲染出来的预览和转换好的音频;清了下次打开工程时重新生成,大工程要等几分钟。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "film"
        ),
        Entry(
            key: "adobe-media-cache",
            names: ["Adobe Media Cache"],
            title: "Adobe 媒体缓存索引",
            group: .appCache,
            tier: .safe,
            rationale: "Adobe 用来登记上面那些媒体缓存的索引;清了会随媒体缓存一起重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "film"
        ),
        Entry(
            key: "adobe-camera-raw",
            names: ["Adobe Camera Raw", "Adobe Camera Raw 2"],
            title: "Adobe Camera Raw 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Photoshop、Lightroom、Bridge 打开原片时生成的预览;清了下次打开图片时自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "photo"
        ),
        Entry(
            key: "blender",
            names: ["Blender", "org.blenderfoundation.blender"],
            title: "Blender 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Blender 工作时保存的临时文件;清了下次启动会慢一点。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cube"
        ),
        Entry(
            key: "sketch",
            names: ["com.bohemiancoding.sketch3"],
            title: "Sketch 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Sketch 设计工具的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "square.on.circle"
        ),
        Entry(
            key: "affinity-designer",
            names: ["com.seriflabs.affinitydesigner2", "Affinity Designer"],
            title: "Affinity Designer 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Affinity Designer 的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "square.on.circle"
        ),
        Entry(
            key: "affinity-photo",
            names: ["com.seriflabs.affinityphoto2", "Affinity Photo"],
            title: "Affinity Photo 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Affinity Photo 的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "square.on.circle"
        ),
        Entry(
            key: "effectcraft",
            names: ["EffectCraft", "ai.storyteller.effectcraft"],
            title: "EffectCraft 渲染缓存",
            group: .appCache,
            tier: .safe,
            rationale: "EffectCraft 为了预览特效而渲染好的帧;清了下次打开工程时重新渲染。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "film"
        ),
        // —— 办公、协作、云盘、AI 应用 ——
        Entry(
            key: "microsoft-teams",
            names: ["com.microsoft.teams2", "Microsoft Teams"],
            title: "Microsoft Teams 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Teams 的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "phone"
        ),
        Entry(
            key: "microsoft-word",
            names: ["com.microsoft.Word", "Microsoft Word"],
            title: "Microsoft Word 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Word 的临时文件;清了自动重建。文档本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc"
        ),
        Entry(
            key: "microsoft-excel",
            names: ["com.microsoft.Excel", "Microsoft Excel"],
            title: "Microsoft Excel 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Excel 的临时文件;清了自动重建。表格文件本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "tablecells"
        ),
        Entry(
            key: "grammarly",
            names: ["com.grammarly.ProjectLlama", "Grammarly"],
            title: "Grammarly 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Grammarly 写作助手的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc"
        ),
        Entry(
            key: "loom",
            names: ["com.loom.desktop"],
            title: "Loom 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Loom 录屏工具的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "video"
        ),
        Entry(
            key: "dropbox",
            names: ["com.dropbox.DropboxMacFileHelper", "Dropbox"],
            title: "Dropbox 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Dropbox 同步用的临时数据;你的文件不会丢,但 Dropbox 之后要把同步文件夹整个重新核对一遍,可能要等一阵。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cloud"
        ),
        Entry(
            key: "google-drive",
            names: ["com.google.GoogleDrive", "Google Drive"],
            title: "Google Drive 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Google Drive 同步用的临时数据;你的文件不会丢,但之后它要重新核对同步内容,可能重新下载一部分。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cloud"
        ),
        Entry(
            key: "onedrive",
            names: ["com.microsoft.OneDrive", "OneDrive"],
            title: "OneDrive 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "OneDrive 同步用的临时数据;你的文件不会丢,但之后它要把同步文件夹整个重新核对一遍,可能要等一阵。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cloud"
        ),
        Entry(
            key: "openai-codex",
            names: ["com.openai.codex"],
            title: "Codex 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Codex 应用与命令行工具的页面和脚本缓存,用的时候重新生成;登录信息和会话记录不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "granola",
            names: ["com.granola.app"],
            title: "Granola 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Granola(AI 会议笔记)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "spokenly",
            names: ["app.spokenly", "app.spokenly.revenuecat"],
            title: "Spokenly 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Spokenly(语音听写应用)的临时数据;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "ollama",
            names: ["com.ollama.Ollama"],
            title: "Ollama 应用缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Ollama 应用的临时数据;清了不丢模型,但下次运行时可能要重新加载模型数据。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "brain"
        ),
        Entry(
            key: "claude-cli-cache",
            names: ["claude-cli-nodejs"],
            title: "Claude Code 日志缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Claude Code 给各个项目的 MCP 服务写的日志,一个项目一个文件夹;清了不影响使用,新日志照常写入。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc.text"
        ),
        // 上游标 safe;拿不准(没联网时订阅状态可能暂时显示不对),落「先检查」
        Entry(
            key: "revenuecat",
            names: ["RevenueCat", "RevenueCatFonts"],
            title: "RevenueCat 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "应用里集成的订阅与内购工具(RevenueCat)存的数据;清了下次启动时重新拉取,没联网时订阅状态可能暂时显示不对。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        // —— 开发类应用(接口调试、数据库客户端、Git 客户端):是普通应用,不进「开发工具」组 ——
        Entry(
            key: "proxyman",
            names: ["com.proxyman.NSProxy", "Proxyman"],
            title: "Proxyman 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Proxyman(抓包与接口调试工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "network"
        ),
        Entry(
            key: "insomnia",
            names: ["com.insomnia.app"],
            title: "Insomnia 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Insomnia(接口调试工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "network"
        ),
        Entry(
            key: "paw-rapi",
            names: ["com.luckymarmot.Paw", "RapidAPI"],
            title: "Paw / RapidAPI 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Paw 与 RapidAPI(接口开发工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "network"
        ),
        Entry(
            key: "tableplus",
            names: ["com.tinyapp.TablePlus", "TablePlus"],
            title: "TablePlus 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "TablePlus(数据库管理工具)的临时文件;清了下次打开时重新生成。数据库本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cylinder"
        ),
        Entry(
            key: "postico",
            names: ["at.eggerapps.Postico", "Postico"],
            title: "Postico 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Postico(PostgreSQL 客户端)的临时文件;清了下次打开时重新生成。数据库本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cylinder"
        ),
        Entry(
            key: "fork-git",
            names: ["com.DanPristupov.Fork"],
            title: "Fork 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Fork(Git 客户端)的临时文件;清了下次打开时重新生成。仓库本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.branch"
        ),
        Entry(
            key: "sourcetree",
            names: ["com.torusknot.SourceTreeNotMAS", "SourceTree"],
            title: "Sourcetree 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Sourcetree(Git 客户端)的临时文件;清了下次打开时重新生成。仓库本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.branch"
        ),
        Entry(
            key: "tower-git",
            names: ["com.fournova.Tower3"],
            title: "Tower 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Tower(Git 客户端)的临时文件;清了下次打开时重新生成。仓库本身不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.branch"
        ),
        Entry(
            key: "jna-libraries",
            names: ["JNA"],
            title: "Java 本地库解包缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Java 应用启动时解包到这里供加载的本地库;清了下次启动时重新解包。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cube"
        ),
        // —— 录屏与截图 ——
        Entry(
            key: "screenflow",
            names: ["net.telestream.screenflow", "ScreenFlow"],
            title: "ScreenFlow 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "ScreenFlow 录屏软件的临时文件;清了下次打开时重新生成,录好的视频不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "video"
        ),
        Entry(
            key: "cleanshot",
            names: ["pl.maketheweb.cleanshotx", "CleanShot"],
            title: "CleanShot X 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "CleanShot X(截图工具)的临时文件;清了下次打开时重新生成,截好的图不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "camera"
        ),
        Entry(
            key: "xnapper",
            names: ["com.xnapper.xnapper", "Xnapper"],
            title: "Xnapper 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Xnapper(截图工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "camera"
        ),
        // —— 小工具、统计与错误报告 ——
        // com.macpaw.CleanMyMac5 是 Pulse 本机实测补的版本号(上游只登记到 4)
        Entry(
            key: "cleanmymac",
            names: ["com.macpaw.CleanMyMac4", "com.macpaw.CleanMyMac5", "CleanMyMac"],
            title: "CleanMyMac 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "CleanMyMac 自己的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "trash"
        ),
        Entry(
            key: "lungo",
            names: ["com.sindresorhus.Lungo", "Lungo"],
            title: "Lungo 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Lungo(防止 Mac 休眠的工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "eye"
        ),
        Entry(
            key: "bartender",
            names: ["com.surteesstudios.Bartender", "Bartender"],
            title: "Bartender 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Bartender(菜单栏整理工具)的临时文件;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "line.3.horizontal"
        ),
        Entry(
            key: "codexbar-cache",
            names: ["com.steipete.codexbar"],
            title: "CodexBar 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "CodexBar(菜单栏用量显示工具)下载的网页与更新文件;清了下次需要时重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "chart.bar"
        ),
        Entry(
            key: "codexbar-usage-history",
            names: ["CodexBar"],
            title: "CodexBar 用量历史",
            group: .appCache,
            tier: .checkFirst,
            rationale: "CodexBar 根据 Claude 与 Codex 的会话日志算出来的用量合计;它能重算,但日志已经不在的那些天数会一直缺着。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "chart.bar"
        ),
        Entry(
            key: "purge-app",
            names: ["io.getpurge.app"],
            title: "Purge 缓存",
            group: .appCache,
            tier: .safe,
            rationale: "Purge(清理工具)自己的临时数据;清了下次打开时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "trash"
        ),
        Entry(
            key: "sentry",
            names: ["io.sentry", "SentryCrash"],
            title: "Sentry 错误报告",
            group: .appCache,
            tier: .safe,
            rationale: "应用里集成的 Sentry(开发者用来跟踪问题的工具)收集的错误与崩溃报告;清了不影响应用,新报告会重新写入。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc.text"
        ),
        Entry(
            key: "datadog",
            names: ["com.datadoghq"],
            title: "Datadog 监控数据",
            group: .appCache,
            tier: .safe,
            rationale: "Datadog(开发者用的监控统计工具)的临时数据;清了不影响应用,它还在运行的话会重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc.text"
        ),
        Entry(
            key: "segment",
            names: ["segment"],
            title: "Segment 统计数据",
            group: .appCache,
            tier: .safe,
            rationale: "Segment(开发者用来收集使用统计的工具)的临时数据;清了不影响应用。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "chart.bar"
        ),
        Entry(
            key: "nt-ware-smartclient",
            names: ["com.nt-ware.SmartClient"],
            title: "NT-ware SmartClient 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "办公室、学校常见的打印管理客户端的缓存;通常清了没事,但客户端可能要重新做一遍初始化。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "printer"
        ),
    ]

    /// 苹果自家的应用与后台服务的缓存:恒「先检查」,不自动勾(见文件头)。
    static let apple: [Entry] = [
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
            key: "amp-library-agent",
            names: ["com.apple.AMPLibraryAgent"],
            title: "Apple 音乐资料库缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "音乐 app 资料库的临时数据;不丢东西,但音乐 app 要花点时间重建资料库界面。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "music.note"
        ),
        Entry(
            key: "amsengagementd",
            names: ["com.apple.amsengagementd"],
            title: "App Store 通知缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "App Store 推荐与通知相关的临时数据;清了系统自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "adprivacyd",
            names: ["com.apple.ap.adprivacyd"],
            title: "苹果广告隐私缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果广告系统用的临时数据;清了对应用和个人数据没有影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gearshape"
        ),
        Entry(
            key: "apple-media-services",
            names: ["com.apple.AppleMediaServices"],
            title: "苹果媒体服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "App Store、Apple TV、Apple Music 的临时数据;清了这些服务按需重建,下次打开可能要重新加载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "appstoreagent",
            names: ["com.apple.appstoreagent"],
            title: "App Store 后台下载缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "App Store 在后台管理下载与更新用的临时文件,里面还有订阅权益的缓存;清了下次打开 App Store 重新拉取,正在进行的更新可能要重来。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "assistantd",
            names: ["com.apple.assistantd", "com.apple.AssistantServices"],
            title: "Siri 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Siri 的临时数据;清了 Siri 自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "beta-enrollment",
            names: ["com.apple.betaenrollmentagent"],
            title: "系统测试版计划缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "与苹果测试版计划相关的临时数据;清了如果还在计划里会重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gearshape"
        ),
        Entry(
            key: "bird",
            names: ["com.apple.bird"],
            title: "iCloud 云盘同步缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "让 iCloud 云盘保持同步的后台服务用的数据;iCloud 上的东西不会丢,但 Mac 之后要重新核对一遍文件状态。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "icloud"
        ),
        Entry(
            key: "businessservicesd",
            names: ["com.apple.businessservicesd"],
            title: "苹果商务服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果的企业与组织账户功能用的临时数据;清了自动重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gearshape"
        ),
        Entry(
            key: "cloudd",
            names: ["com.apple.cloudd"],
            title: "iCloud 后台服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "处理 iCloud 数据的后台服务用的数据;iCloud 上的东西不会丢,但 Mac 之后要重新同步。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "icloud"
        ),
        Entry(
            key: "cloud-telemetry",
            names: ["com.apple.CloudTelemetry"],
            title: "苹果使用情况统计",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果匿名使用统计的临时数据;清了没有任何影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc.text"
        ),
        Entry(
            key: "ctcategories",
            names: ["com.apple.ctcategories.service"],
            title: "内容分类服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统给内容分类(屏幕使用时间、家长控制这些功能要用)的临时数据;清了系统重建分类缓存。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gearshape"
        ),
        Entry(
            key: "donotdisturbd",
            names: ["com.apple.donotdisturbd"],
            title: "专注模式缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "专注模式与勿扰设置的临时数据;清了系统自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "moon"
        ),
        Entry(
            key: "duetexpertd",
            names: ["com.apple.duetexpertd"],
            title: "Siri 建议学习数据",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Siri 建议与应用预测所依据的本机学习数据;清了它会忘掉已经学到的使用习惯,重新开始学。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "feature-access-agent",
            names: ["com.apple.FeatureAccessAgent"],
            title: "功能权限缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统用来管理「哪些应用能用哪些功能」的临时数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gearshape"
        ),
        Entry(
            key: "feedbacklogger",
            names: ["com.apple.feedbacklogger"],
            title: "苹果反馈日志",
            group: .appCache,
            tier: .checkFirst,
            rationale: "准备发给苹果做诊断反馈的临时日志;清了没有任何影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "doc.text"
        ),
        Entry(
            key: "fileprovider-appstore",
            names: ["com.apple.FileProviderDaemon.AppStoreService"],
            title: "App Store 文件服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "帮 App Store 管理文件的后台服务的临时数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "findmy",
            names: ["com.apple.findmy.fmipcore"],
            title: "查找缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "「查找」用来定位苹果设备的临时数据;不丢东西,但设备位置要过一阵才重新显示。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "location"
        ),
        Entry(
            key: "geoanalyticsd",
            names: ["com.apple.geoanalyticsd"],
            title: "位置分析缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果位置分析系统的临时数据;清了对地图和其它应用没有影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "location"
        ),
        Entry(
            key: "helpd",
            names: ["com.apple.helpd"],
            title: "帮助系统缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "macOS 自带帮助的临时数据(帮助索引等);清了下次打开帮助时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "questionmark.circle"
        ),
        Entry(
            key: "homed",
            names: ["com.apple.homed", "com.apple.HomeKit"],
            title: "家庭缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "家庭 app 与智能家居设备的临时数据;已配对的设备不会掉,但家庭 app 在重新同步完之前可能显示不全或反应慢。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "house"
        ),
        Entry(
            key: "itunes",
            names: ["com.apple.iTunes"],
            title: "iTunes 与 Apple Music 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "iTunes 与 Apple Music 的临时数据(专辑封面、媒体预览);不丢东西,但封面要在浏览时重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "music.note"
        ),
        Entry(
            key: "managedappdistribution",
            names: ["com.apple.managedappdistributionagent"],
            title: "托管应用分发缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统用来分发和管理应用(常见于公司、学校统一管理的 Mac)的后台服务的临时数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "nsurlsessiond",
            names: ["com.apple.nsurlsessiond"],
            title: "后台下载缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "应用在后台下载内容时的进度状态;清了可能打断正在进行的下载,那个应用得重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.down.circle"
        ),
        Entry(
            key: "parsecd",
            names: ["com.apple.parsecd"],
            title: "Siri 与聚焦理解缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "帮 Siri 和聚焦理解自然语言的后台服务的临时数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "proactive-eventtracker",
            names: ["com.apple.proactive.eventtracker"],
            title: "Siri 建议数据",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Siri 建议已经学到的你的习惯和日程;清了个性化建议会回到初始状态,直到它重新学会。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "sparkles"
        ),
        Entry(
            key: "remindd",
            names: ["com.apple.remindd"],
            title: "提醒事项后台缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "提醒事项 app 在后台用的临时数据;清了安全,下次打开提醒事项时要重新加载一下。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "checklist"
        ),
        Entry(
            key: "shazam",
            names: ["com.apple.shazamlibrary.cloud"],
            title: "Shazam 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Shazam 识别音乐用的临时数据;清了它会重新下载需要的部分。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "music.note"
        ),
        Entry(
            key: "siri-tts",
            names: ["com.apple.sirittsd", "SiriTTS"],
            title: "Siri 语音数据",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Siri 说话用的语音与朗读数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "waveform"
        ),
        Entry(
            key: "spotlight",
            names: ["com.apple.Spotlight"],
            title: "聚焦搜索索引",
            group: .appCache,
            tier: .checkFirst,
            rationale: "聚焦用来搜索整台 Mac 的索引;不丢东西,但系统重建索引期间搜索又慢又不全,可能要很久。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "magnifyingglass"
        ),
        Entry(
            key: "tipsd",
            names: ["com.apple.tipsd"],
            title: "使用技巧缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "「使用技巧」app 的临时数据;清了没有任何影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "lightbulb"
        ),
        Entry(
            key: "videoconference",
            names: ["com.apple.VideoConference"],
            title: "FaceTime 与视频通话缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "FaceTime 等苹果视频通话功能的临时数据;清了需要时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "video"
        ),
        Entry(
            key: "gamed",
            names: ["com.apple.gamed"],
            title: "游戏中心缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "游戏中心(管理游戏分数与成就)的临时数据;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gamecontroller"
        ),
        Entry(
            key: "chrono",
            names: ["com.apple.chrono"],
            title: "小组件快照缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "桌面与通知中心小组件保存的快照;清了小组件会自己重画,重画好之前可能短暂显示空白。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "square.grid.2x2"
        ),
        Entry(
            key: "translation",
            names: ["com.apple.translationd"],
            title: "系统翻译缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "macOS 自带翻译功能的临时数据;清了翻译服务按需重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "character.bubble"
        ),
        Entry(
            key: "gamekit",
            names: ["GameKit"],
            title: "GameKit 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果游戏框架(GameKit)的临时数据;清了下次打开游戏时重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "gamecontroller"
        ),
        Entry(
            key: "apple-maps",
            names: ["com.apple.Maps"],
            title: "地图缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "苹果地图存的地图瓦片与位置数据;不丢东西,但要在用地图时重新下载,离线地图要重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "map"
        ),
        Entry(
            key: "apple-photos",
            names: ["com.apple.Photos"],
            title: "照片缩略图缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "照片 app 的缩略图与预览;照片本身不会删,但照片 app 要把每张缩略图重做一遍,图库大的话要很久。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "photo"
        ),
        Entry(
            key: "apple-mail",
            names: ["com.apple.mail"],
            title: "邮件缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "邮件 app 的临时文件与邮件预览;邮件不会删,但之后邮件要重建索引,建好之前搜索结果可能不全。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "envelope"
        ),
        Entry(
            key: "apple-music-app",
            names: ["com.apple.Music"],
            title: "音乐 app 缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "音乐 app 的临时文件;不丢东西,但封面与资料库数据要在使用中重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "music.note"
        ),
        Entry(
            key: "network-cache",
            names: ["com.apple.networkserviceproxy"],
            title: "网络响应缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统为了加快连接而缓存的网络响应;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "network"
        ),
        Entry(
            key: "screenshot-app",
            names: ["com.apple.screencaptureui"],
            title: "系统截图缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "macOS 自带截图工具的临时文件;清了没有任何影响。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "camera"
        ),
        Entry(
            key: "dictionary-services",
            names: ["com.apple.DictionaryServices"],
            title: "词典缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "系统词典与「查询」功能的临时数据;清了下次查词时重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "character.book.closed"
        ),
        Entry(
            key: "promoted-content",
            names: ["com.apple.ap.PromotedContentJetService"],
            title: "App Store 广告缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "App Store 里展示的广告数据;清了需要时重新下载。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "intelligenceflowd-cache",
            names: ["com.apple.intelligenceflow.intelligenceflowd"],
            title: "Apple 智能服务缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "Apple 智能的某个服务下载的网页与编译好的模型;Apple 智能的模型本体不在这里。清了系统按需重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "brain"
        ),
        Entry(
            key: "ssu",
            names: ["ssu"],
            title: "系统更新缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "macOS 软件更新系统的临时数据;清了下次检查更新时重新生成。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
        Entry(
            key: "storekitagent",
            names: ["com.apple.storekitagent"],
            title: "App Store 内购缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "应用内购买与 App Store 交易的临时数据;不丢东西,但应用可能要你恢复购买或重新登录。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "bag"
        ),
        Entry(
            key: "ams-migrator",
            names: ["AMSDataMigratorTool"],
            title: "App Store 数据迁移工具缓存",
            group: .appCache,
            tier: .checkFirst,
            rationale: "App Store 服务用来迁移账号或媒体数据的工具留下的临时文件夹;清了自动重建。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "arrow.triangle.2.circlepath"
        ),
    ]

    /// Pulse 自定(本机真案,来源不是上游)。
    static let custom: [Entry] = [
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
    public static let entries: [Entry] = browsers + apps + apple + custom
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

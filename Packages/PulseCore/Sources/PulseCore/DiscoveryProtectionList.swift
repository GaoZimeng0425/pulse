import Foundation

// MARK: - 保护名单(p7-cleaner/02;GLOSSARY「保护名单」)

//
// 永不进通用发现的条目。与安全白名单并存、分工不同:安全白名单管「能否自动勾选」,
// 保护名单管「永不列出」。只收窄、永不扩大——加一条只会让清单更短。
// 首批四类:按名字(路径类的事实,各自带出处)、按软件类别(端点防护 / 设备管理 /
// 企业组网——动了会触发公司的安全告警)、个人数据目录、系统所有。
// 浏览器用户资料目录不在这里:通用发现在应用数据目录下只收名字明确的缓存子目录,
// 资料目录本身与它下面几层都轮不到,靠结构就进不来。
// 「正在运行的应用」也受保护,但它随时间变:由通用发现的调用方每回现传,不写在这里。
// 对齐对象的事故编号只借事实(哪个路径、什么条件下出的事),零搬码。

public enum DiscoveryProtectionList {
    /// 条目名(小写)包含即保护。密码与密钥类沿用孤儿检测的敏感名单(同一份常量,
    /// 不另抄——两处各写一份迟早漂移)。
    public static let nameTokens: [String] = OrphanRedlines.sensitiveNameSubstrings + [
        // 日历缓存:日历代理常驻,清了崩到重新登录(对齐对象事故 #1508)。
        "calendar",
        // 壁纸缩略图:清了系统设置里的壁纸封面变成云下载占位图(对齐对象事故 #1118)。
        "wallpaper",
        // 接力 / 通用剪贴板的中转缓存:同步进行到一半的条目不能断(对齐对象事故 #1178)。
        "pasteboard", "useractivityd", "handoff",
        // 编译模型缓存:守护进程在跑时清了,识别功能坏到它重启。
        "e5bundlecache",
        // 以下两个是对齐对象在通用扫描上的硬跳过:前者的目录名下是 Chrome 运行时的
        // 网络缓存(它自己的记录是「清了连着七次失败」);后者是 Rust 构建缓存的垫片与
        // 调度租约,正在用的检出链接进来,清了断构建。
        "google", "mbx",
    ]

    /// 软件类别:端点防护、设备管理、企业组网。本机在场的四家(SentinelOne / Santa /
    /// CorpLink / Tailscale)必须在内。按条目名包含匹配,宁可多藏不可漏。
    public static let vendorTokens: [String] = [
        // 端点防护
        "sentinel", "northpolesec", "santa", "corplink",
        "crowdstrike", "carbonblack", "cylance", "sophos", "eset", "kaspersky", "symantec",
        "norton", "mcafee", "trellix", "defender", "tanium", "trendmicro",
        "qianxin", "tianqing", "huorong", "sangfor",
        // 设备管理
        "jamf", "kandji", "intune",
        // 企业组网
        "tailscale", "wireguard", "openvpn", "tunnelblick", "openconnect", "netbird",
        "twingate", "zerotier", "cloudflare",
        "globalprotect", "zscaler", "netskope", "anyconnect", "forticlient", "pulsesecure",
    ]

    /// 整名相等才算的个人数据目录:邮件 / 信息 / 照片 / 通讯录 / 备忘录 / 日历 / 提醒事项 /
    /// 设备备份 / Safari。它们装的是唯一一份的个人数据,不是缓存。
    public static let dataDirectoryNames: Set<String> = [
        "mail", "messages", "photos", "contacts", "addressbook", "notes", "calendars",
        "reminders", "mobilesync", "safari",
    ]

    /// 不带 `com.apple.` 前缀的系统守护进程缓存(整名相等,小写比较):iCloud 同步库、
    /// 地图瓦片、钱包卡票、游戏中心、家庭圈、缩略图。只认前缀会漏掉它们。首批按本机
    /// 缓存目录实测,发现一个补一个;对齐对象的通用扫描同样硬跳过 CloudKit 与 FamilyCircle。
    public static let systemDaemonCacheNames: Set<String> = [
        "cloudkit", "geoservices", "passkit", "gamekit", "quicklook",
        "familycircle", "familycircled", "thumbnailscache",
    ]

    /// 系统所有:`com.apple.` 前缀、名为「Apple」的目录,或不带前缀的那批守护进程缓存。
    /// 它们的守护进程常年常驻,「在运行就跳过」对它们没有可靠信号;认得的苹果缓存走
    /// 知识库逐条担保。
    public static func isSystemOwned(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("com.apple.")
            || lowered == "apple"
            || systemDaemonCacheNames.contains(lowered)
    }

    /// 条目是否受保护。`name` = 条目自己的名字(路径最后一段)。
    public static func isProtected(name: String) -> Bool {
        if isSystemOwned(name: name) {
            return true
        }
        let lowered = name.lowercased()
        if nameTokens.contains(where: lowered.contains) || vendorTokens.contains(where: lowered.contains) {
            return true
        }
        return dataDirectoryNames.contains(lowered)
    }
}

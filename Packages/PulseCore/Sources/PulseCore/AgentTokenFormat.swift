import Foundation

/// token 读数短型(智能体页全部 token 显示的唯一出处;agent-tab/08 自 app 层
/// `agentTokenText` 收进核心包并加 B 档):999 / 556k / 6.9M / 1.9B。
/// 小数点手拼、不随区域漂移;M 档四舍五入进到 1000.0M 时直接升 B。
public enum AgentTokenFormat {
    public static func short(_ tokens: Int) -> String {
        let millionTenths = Int((Double(tokens) / 100_000).rounded())
        if tokens >= 1_000_000, millionTenths < 10000 {
            return "\(millionTenths / 10).\(millionTenths % 10)M"
        }
        if tokens >= 1_000_000 {
            let billionTenths = Int((Double(tokens) / 100_000_000).rounded())
            return "\(billionTenths / 10).\(billionTenths % 10)B"
        }
        if tokens >= 1000 {
            return "\(tokens / 1000)k"
        }
        return "\(tokens)"
    }

    /// 同格式拆两段给大数字(数值整号 + 单位半号):2.4B → ("2.4", "B")。
    public static func figure(_ tokens: Int) -> (value: String, unit: String) {
        let text = short(tokens)
        if let unit = text.last, "kMB".contains(unit) {
            return (String(text.dropLast()), String(unit))
        }
        return (text, "")
    }
}

import Foundation

// MARK: - 排除目录(p4-cleaner/04;GLOSSARY「排除目录」)

//
// 用户标记永不进入扫描的目录前缀。语义只有一条:**只收窄,永不扩大**——加一条排除
// 只会让清单变短,不会让任何东西变得可删(ADR-0008)。
// 本文件是扫描侧(SpaceScanEngine 不下潜)与删除侧(CleanPlan 删前二次判定)**共用的
// 唯一判定**:票面要求"扫描与删除两处生效",两处各写一份前缀匹配迟早漂移,
// 所以判定只在这里出一次,两处只调用。

public enum CleanExclusions {
    /// `path` 是否落在任一排除前缀之下(含等于前缀本身)。
    /// 前缀按路径分量匹配:`/a/b` 排除 `/a/b` 与 `/a/b/c`,不排除 `/a/bc`。
    public static func isExcluded(_ path: String, by prefixes: [String]) -> Bool {
        let target = PathNormalization.normalize(path)
        return prefixes.contains { prefix in
            let p = PathNormalization.normalize(prefix)
            return target == p || target.hasPrefix(p + "/") || p == "/"
        }
    }

    /// 加入一条排除,返回新列表(纯值;持久化归 app 侧 store)。
    /// - 归一后与现有条目相同 → 幂等不重复;
    /// - 已被现有更宽前缀覆盖 → 不加(加了也不改变任何判定结果);
    /// - 比现有若干条更宽 → 加入并吸收被它覆盖的窄条目(列表保持最简)。
    public static func adding(_ prefix: String, to prefixes: [String]) -> [String] {
        let normalized = PathNormalization.normalize(prefix)
        guard !normalized.isEmpty else { return prefixes }
        if isExcluded(normalized, by: prefixes) {
            return prefixes
        }
        var kept = prefixes.filter { !isExcluded($0, by: [normalized]) }
        kept.append(normalized)
        return kept
    }

    /// 移除一条排除(精确匹配归一后的条目);不在列表时原样返回。
    public static func removing(_ prefix: String, from prefixes: [String]) -> [String] {
        let normalized = PathNormalization.normalize(prefix)
        return prefixes.filter { PathNormalization.normalize($0) != normalized }
    }
}

import AppKit
import PulseCore
import SwiftUI

/// 设置窗「清理」页(p4-cleaner/04 排除目录 + 05 清理扫描根):
/// - 排除目录(GLOSSARY)图形化增删——添加用文件夹选择器,行内删除;清理页右键
///   「排除此目录」加进来的也在这里管理。排除只收窄,语义在 PulseCore.CleanExclusions。
/// - 清理扫描根(05,用户拍板与归组的项目根**两套配置、零共享**):出厂给常见
///   开发目录建议清单(勾选即加),特殊位置(如 ~/Documents/Learn/macos)用
///   文件夹选择器自添。根的直接子目录 = 项目;项目产物的匹配语义在 PulseCore。
/// 两个视图都只做呈现与转发,持久化在各自 Store(*Tests)。
struct CleanerSettingsView: View {
    let store: CleanExclusionsStore
    let scanRoots: CleanScanRootsStore

    /// 出厂建议(spec 用户故事 24:常见开发目录建议清单,勾选追加)。
    /// 只当默认值提议,不做存在性探测——零 IO,配错顶多扫不出产物,界面有引导。
    private static let suggestedRoots: [(label: String, path: String)] = [
        ("文稿", "~/Documents"),
        ("下载", "~/Downloads"),
        ("桌面", "~/Desktop"),
        ("Developer", "~/Developer"),
        ("Projects", "~/Projects"),
        ("dev", "~/dev"),
        ("code", "~/code"),
        ("src", "~/src"),
    ]

    var body: some View {
        Form {
            scanRootsSection
            exclusionSection
            Section {
                Text("清理扫描根与上方「项目根目录」页的归组配置互不影响(两套独立配置)。项目 = 扫描根的直接子目录;正在使用的项目(终端 / 构建 / git 活动在其中)永不进入清理,且每次清理前都会重查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: 清理扫描根(05)

    private var scanRootsSection: some View {
        Section("清理扫描根(项目产物从这里找)") {
            ForEach(Self.suggestedRoots, id: \.path) { suggestion in
                suggestedRow(suggestion)
            }
            ForEach(scanRoots.paths.filter { !Self.suggestedPaths.contains($0) }, id: \.self) { path in
                customRootRow(path)
            }
            Button {
                addScanRoot()
            } label: {
                Label("自添目录…", systemImage: "plus")
            }
        }
    }

    private static var suggestedPaths: Set<String> {
        Set(suggestedRoots.map {
            PathNormalization.normalize(($0.path as NSString).expandingTildeInPath)
        })
    }

    /// 建议行:勾选即加、取消勾即删(同一个 store,清单页即时反映)。
    /// 展示用 ~ 写法,存储用展开归一后的绝对路径(与扫描树同口径)。
    private func suggestedRow(_ suggestion: (label: String, path: String)) -> some View {
        let normalized = PathNormalization.normalize(
            (suggestion.path as NSString).expandingTildeInPath
        )
        return HStack {
            Toggle(isOn: Binding(
                get: { scanRoots.paths.contains(normalized) },
                set: { included in
                    if included {
                        scanRoots.add(normalized)
                    } else {
                        scanRoots.remove(normalized)
                    }
                }
            )) {
                Text("\(suggestion.path)(\(suggestion.label))")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    /// 自添行:目录图标 + 路径 + 删除(与排除行同款)。
    private func customRootRow(_ path: String) -> some View {
        HStack {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.secondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                scanRoots.remove(path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除该扫描根")
        }
    }

    private func addScanRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要作为清理扫描根的目录(项目 = 它的直接子目录)"
        if panel.runModal() == .OK {
            for url in panel.urls {
                scanRoots.add(url.path)
            }
        }
    }

    // MARK: 排除目录(04)

    private var exclusionSection: some View {
        Section("排除目录") {
            ForEach(store.paths, id: \.self) { path in
                exclusionRow(path)
            }
            if store.paths.isEmpty {
                Text("尚无排除目录。清理页右键任意清单行可排除该目录,或在这里添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                addExclusion()
            } label: {
                Label("添加排除目录…", systemImage: "plus")
            }
        }
    }

    /// 单行:目录图标 + 路径(中段截断)+ 删除按钮。
    private func exclusionRow(_ path: String) -> some View {
        HStack {
            Image(systemName: "folder.badge.minus")
                .foregroundStyle(.secondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                store.remove(path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("取消排除该目录")
        }
    }

    /// 文件夹选择器:只选目录。无沙盒(ADR-0002)→ 纯路径字符串即可,无需书签。
    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要排除出清理扫描的目录"
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.add(url.path)
            }
        }
    }
}

#Preview("已有配置") {
    CleanerSettingsView(
        store: CleanExclusionsStore(
            load: { ["/Users/x/Library/Caches/JetBrains", "/Users/x/.gradle"] },
            persist: { _ in }
        ),
        scanRoots: CleanScanRootsStore(
            load: { ["/Users/x/Documents/Learn/macos"] },
            persist: { _ in }
        )
    )
}

#Preview("空配置") {
    CleanerSettingsView(
        store: CleanExclusionsStore(load: { [] }, persist: { _ in }),
        scanRoots: CleanScanRootsStore(load: { [] }, persist: { _ in })
    )
}

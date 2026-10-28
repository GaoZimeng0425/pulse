import AppKit
import PulseCore
import SwiftUI

/// 设置窗「清理」页(p4-cleaner/04):排除目录(GLOSSARY)列表的图形化增删——
/// 添加用文件夹选择器(NSOpenPanel 选目录),行内删除;清理页右键「排除此目录」加进来的
/// 也在这里管理。排除只收窄(加一条只会让清单变短),语义在 PulseCore.CleanExclusions,
/// 持久化在 CleanExclusionsStore(CleanExclusionsStoreTests),本视图只做呈现与转发。
struct CleanerSettingsView: View {
    let store: CleanExclusionsStore

    var body: some View {
        Form {
            Section("排除目录") {
                ForEach(store.paths, id: \.self) { path in
                    row(path)
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
            Section {
                Text("排除目录只收窄、永不扩大:扫描不进入这些目录,已勾选的项若落在其下也会在删除前被剔除。更宽的目录会吸收它下面已有的条目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// 单行:目录图标 + 路径(中段截断)+ 删除按钮。
    private func row(_ path: String) -> some View {
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

#Preview("已有排除") {
    CleanerSettingsView(
        store: CleanExclusionsStore(
            load: { ["/Users/x/Library/Caches/JetBrains", "/Users/x/.gradle"] },
            persist: { _ in }
        )
    )
}

#Preview("空列表") {
    CleanerSettingsView(store: CleanExclusionsStore(load: { [] }, persist: { _ in }))
}

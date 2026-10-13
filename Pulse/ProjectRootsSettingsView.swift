import SwiftUI
import AppKit

/// 设置窗内容(工单 07):项目根(GLOSSARY)目录列表的图形化增删——
/// 添加用文件夹选择器(NSOpenPanel,选择目录),行内删除。
/// 窗口与选择器行为按 spec 手动验收;列表增删 / 持久化逻辑在
/// ProjectRootsStoreTests 单测覆盖,本视图只做呈现与转发。
struct ProjectRootsSettingsView: View {
    let store: ProjectRootsStore

    var body: some View {
        Form {
            Section("项目根目录") {
                ForEach(store.projectRoots, id: \.self) { root in
                    rootRow(root)
                }
                if store.projectRoots.isEmpty {
                    Text(
                        "尚未添加项目根。添加后,rustc / node 等开发进程会按工作目录"
                            + "归到「项目名 @ worktree」组。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button {
                    addRoot()
                } label: {
                    Label("添加项目根…", systemImage: "plus")
                }
            }
            Section {
                Text("项目根是项目归因的匹配锚点:开发进程的工作目录落在某个根之下即归入该项目;命中 .worktrees/<名> 时按 worktree 分组。改动在下一轮采样内生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }

    /// 单个项目根行:目录图标 + 路径(中段截断)+ 删除按钮。
    private func rootRow(_ root: String) -> some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(root)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                store.remove(root)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除该目录")
        }
    }

    /// 文件夹选择器:只选目录。无沙盒(ADR-0002)→ 纯路径字符串即可,无需书签。
    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择项目根目录"
        if panel.runModal() == .OK, let url = panel.url {
            store.add(url.path)
        }
    }
}

// MARK: - 预览(Synthetic 读闭包,无落盘副作用)

#Preview("已有根") {
    ProjectRootsSettingsView(
        store: ProjectRootsStore(
            load: { ["/Users/x/work/octok-client", "/Users/x/work/vitals"] },
            persist: { _ in }
        )
    )
}

#Preview("空列表") {
    ProjectRootsSettingsView(
        store: ProjectRootsStore(load: { [] }, persist: { _ in })
    )
}

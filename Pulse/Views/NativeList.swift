import AppKit
import SwiftUI

// MARK: - 通用原生长列表(native-list,2026-10-31 用户拍板)

//
// AppKit NSTableView 承载 SwiftUI 行:行视图照旧是 SwiftUI(样式只有一份),容器换成
// 业界原生列表的三件套——
// 1. 行视图复用:滚出视野的行按复用类型(kind)回收,装上新行的内容,不新建宿主;
// 2. 行高缓存:同类行(排行行)按 kind 只量一次;各异的行(卡片、展开行)按 key 量一次
//    缓存,只在可见时随数据更新复量,滚动时表格不再逐行问 SwiftUI 多高;
// 3. 按位置更新:行结构(kind / key 序列)不变时只给可见行换内容,不删行插行。
// 外加关掉用不到的选中高亮与键盘焦点。弹窗与主窗口共用(主窗口 2026-11-28 接入,
// main-window-native-list;行拼装见 MetricTabNativeRows)。
// 为什么不用 SwiftUI List:每滚进一行它都新建 / 重配一个宿主、自动测高、重算焦点链,
// 真机快速滚动 40–70%(popover-list 采样);探针里本方案稳定 20–25%。

/// 原生列表的一行。
struct NativeListRow {
    enum Height {
        /// 同 kind 行同高:按 kind 只量一次(排行行)。
        case uniform
        /// 各行自量,按 key 缓存;可见时随数据更新复量(卡片、展开行)。
        case measured(key: String)
    }

    /// 复用类型:同 kind 的行视图互相回收,内容视图类型应一致(换类型 = 重建视图图)。
    let kind: String
    let height: Height
    let content: () -> AnyView
}

extension EnvironmentValues {
    /// 原生列表的行宽(列宽):量高的离屏宿主与可见行拿同一个值,按宽度切排法的内容
    /// 据此当场决定,不经「量宽 → @State」(两处是不同视图实例,状态各算各的;
    /// main-window-native-list)。nil = 不在原生列表里。
    @Entry var nativeListRowWidth: CGFloat?
    /// 行内容宽 = 行宽扣掉宿主页边(MetricTabNativeRows 设);卡片按它切排法。
    @Entry var listContentWidth: CGFloat?
}

struct NativeList: NSViewRepresentable {
    let rows: [NativeListRow]
    /// 变化时滚回顶部(切 tab)。
    let resetToken: AnyHashable
    /// 竖向滚动条:弹窗不显(360pt 定宽省一条),主窗口显(系统浮层滚动条,同原 ScrollView)。
    var showsVerticalScroller = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView(showsVerticalScroller: showsVerticalScroller)
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, resetToken: resetToken)
    }

    /// 给多大占多大:不声明时 SwiftUI 每次布局都对整个滚动视图 + 表格做 AppKit 适配尺寸
    /// 测量(fittingSize),滚动中逐帧发生(离屏自动滚动采样)。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSScrollView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let table = NSTableView()
        private let scrollView = NSScrollView()
        private var rows: [NativeListRow] = []
        /// 行结构签名(kind + 高度 key):不变 = 只换可见行内容。
        private var signature: [String] = []
        private var resetToken: AnyHashable?
        private var uniformHeights: [String: CGFloat] = [:]
        private var measuredHeights: [String: CGFloat] = [:]
        /// 量高用的离屏宿主,按 kind 各一个(视图类型稳定,复量不重建视图图)。
        private var sizers: [String: NSHostingController<AnyView>] = [:]
        private var width: CGFloat = 0
        /// 拖窗口改宽期间欠着的自量行重量(松手补)。
        private var needsFullRemeasure = false

        func makeScrollView(showsVerticalScroller: Bool) -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.intercellSpacing = .zero
            table.backgroundColor = .clear
            table.gridStyleMask = []
            table.selectionHighlightStyle = .none
            table.usesAutomaticRowHeights = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.focusRingType = .none
            table.refusesFirstResponder = true
            table.dataSource = self
            table.delegate = self

            scrollView.documentView = table
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = showsVerticalScroller
            scrollView.autohidesScrollers = true
            scrollView.hasHorizontalScroller = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidEndLiveResize(_:)),
                name: NSWindow.didEndLiveResizeNotification,
                object: nil
            )
            return scrollView
        }

        func update(rows newRows: [NativeListRow], resetToken token: AnyHashable) {
            rows = newRows
            let newSignature = newRows.map(Self.signature)
            if newSignature != signature {
                signature = newSignature
                table.reloadData()
            } else {
                refreshVisibleRows()
            }
            if token != resetToken {
                resetToken = token
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        // MARK: 数据源 / 代理

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row), width > 0 else { return 1 }
            let item = rows[row]
            switch item.height {
            case .uniform:
                if let cached = uniformHeights[item.kind] {
                    return cached
                }
                let height = measure(item)
                uniformHeights[item.kind] = height
                return height
            case let .measured(key):
                if let cached = measuredHeights[key] {
                    return cached
                }
                let height = measure(item)
                measuredHeights[key] = height
                return height
            }
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let item = rows[row]
            let identifier = NSUserInterfaceItemIdentifier(item.kind)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeListCell
                ?? NativeListCell(identifier: identifier)
            cell.rootView = cellContent(item)
            return cell
        }

        func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
            false
        }

        // MARK: 内部

        /// 结构不变的数据更新:只给可见行换内容。可见自量行的高度只认它自报的自然高
        /// (cellContent),不再拿离屏量高器复量——量高器是另一个视图实例,行内局部
        /// @State(智能体页切范围、展开项目)在它那里永远是默认值,复量会把用户撑开的
        /// 行压回默认高、而可见内容自然高没变不会再自报(评审 HIGH,2026-11-28)。
        private func refreshVisibleRows() {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< min(visible.location + visible.length, rows.count) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeListCell {
                    cell.rootView = cellContent(rows[row])
                }
            }
        }

        /// 按当前列宽量一行的理想高度(离屏宿主,按 kind 复用)。
        private func measure(_ item: NativeListRow) -> CGFloat {
            let sizer = sizers[item.kind] ?? NSHostingController(rootView: AnyView(EmptyView()))
            sizers[item.kind] = sizer
            sizer.rootView = rowContent(item)
            let size = sizer.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            guard size.height.isFinite, size.height > 0 else { return 1 }
            return ceil(size.height)
        }

        /// 行内容 + 行宽环境值(量高与显示同一宽度)。
        private func rowContent(_ item: NativeListRow) -> AnyView {
            AnyView(item.content().environment(\.nativeListRowWidth, width))
        }

        /// 可见行的内容:自量行另外按自然高排版并把它报回来(高度自校正)。行内的局部
        /// 状态(下钻点开进程详情、项目明细展开)只在行自己的宿主里刷新,宿主 body 不重跑,
        /// 列表收不到更新——不自报,行高要等下一轮数据刷新(主窗口 5s)才跟上,期间内容
        /// 被裁或留白。自然高 = 不限高量法下的高度,与离屏量高同一口径,不随行高回馈。
        private func cellContent(_ item: NativeListRow) -> AnyView {
            guard case let .measured(key) = item.height else { return rowContent(item) }
            return AnyView(
                rowContent(item)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                        self?.naturalHeightChanged(key: key, height: height)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
            )
        }

        /// 自量行报来的自然高与缓存差半点以上:更新缓存,只通知用到该 key 的行。
        private func naturalHeightChanged(key: String, height: CGFloat) {
            let rounded = ceil(height)
            guard rounded > 0, abs(rounded - (measuredHeights[key] ?? 0)) > 0.5 else { return }
            measuredHeights[key] = rounded
            var changed = IndexSet()
            for (index, row) in rows.enumerated() {
                if case let .measured(rowKey) = row.height, rowKey == key {
                    changed.insert(index)
                }
            }
            guard !changed.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }

        /// 列宽变了(首帧 0 → 实宽、拖窗口改宽):同高行按新宽重量;自量行在拖动中不全量
        /// 重量(每帧量一遍全部整卡与展开下钻太贵,弹窗定宽从没付过这笔),可见的那几行
        /// 随新宽自报;松手(didEndLiveResize)再整体作废重量一次,屏外行也对上新宽。
        @objc private func clipFrameDidChange() {
            let newWidth = scrollView.contentView.bounds.width
            guard abs(newWidth - width) > 0.5 else { return }
            width = newWidth
            uniformHeights.removeAll()
            if scrollView.inLiveResize {
                needsFullRemeasure = true
            } else {
                measuredHeights.removeAll()
            }
            table.reloadData()
        }

        /// 拖窗口松手:拖动中欠下的自量行重量一次补齐。
        @objc private func windowDidEndLiveResize(_ note: Notification) {
            guard needsFullRemeasure, (note.object as? NSWindow) === scrollView.window else { return }
            needsFullRemeasure = false
            measuredHeights.removeAll()
            table.reloadData()
        }

        private static func signature(_ row: NativeListRow) -> String {
            switch row.height {
            case .uniform: row.kind
            case let .measured(key): "\(row.kind)|\(key)"
            }
        }
    }
}

/// 原生列表的行视图:SwiftUI 宿主,不向外报尺寸约束(行高由列表给)。
final class NativeListCell: NSHostingView<AnyView> {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(rootView: AnyView(EmptyView()))
        self.identifier = identifier
        sizingOptions = []
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// 不参与键盘焦点链:表格每挂上一行都让该行宿主重算整棵 SwiftUI 树的焦点顺序
    /// (NSTableRowData._updateKeyViewLoopForRowView → FocusBridge,离屏自动滚动采样
    /// 约占滚动开销 25%)。弹窗不走 Tab 导航,行内按钮仍可点击。覆盖的是 AppKit 内部
    /// 选择子(签名 `-(id)`,返回本子树焦点链的末尾视图;叶子视图返回自身——离屏实测),
    /// 这里按叶子处理返回 self。系统改名时此覆盖静默失效,只是回到不省这笔开销。
    @objc(_recursiveSetDefaultKeyViewLoop)
    func skipDefaultKeyViewLoop() -> NSView {
        self
    }
}

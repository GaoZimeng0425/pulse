@testable import Pulse
@testable import PulseCore
import XCTest

/// 项目根列表的持久层(工单 07):增删即落盘(UserDefaults 注入独立 suite 隔离),
/// 重启(新 store 读同一 defaults)后列表保留。归组的热更新传播
/// 在 GroupingPipelineTests 的"项目根热更新"用例覆盖。
///
/// 断言用的键名字面量 "projectRoots" 是独立事实来源:键名即持久化契约,改动会 orphan 旧数据。
@MainActor
final class ProjectRootsStoreTests: XCTestCase {
    /// 每测独立的 UserDefaults suite;测试结束清理持久域,不留垃圾 plist。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ProjectRootsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { [suiteName] in
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    // MARK: 启动时读持久化

    /// 重启后保留:新建 store 读出上次落盘的根列表。
    func testInitLoadsPersistedRoots() {
        let defaults = makeDefaults()
        defaults.set(
            ["/Users/x/work/octok-client", "/Users/x/work/vitals"],
            forKey: "projectRoots"
        )

        XCTAssertEqual(
            ProjectRootsStore(defaults: defaults).projectRoots,
            ["/Users/x/work/octok-client", "/Users/x/work/vitals"]
        )
    }

    /// 无持久化值(首次启动/配置为空):空列表起步,不报错。
    func testInitWithoutPersistedValueStartsEmpty() {
        XCTAssertTrue(ProjectRootsStore(defaults: makeDefaults()).projectRoots.isEmpty)
    }

    // MARK: 增删即落盘

    func testAddPersistsRoot() {
        let defaults = makeDefaults()
        let store = ProjectRootsStore(defaults: defaults)

        store.add("/Users/x/work/octok-client")

        XCTAssertEqual(store.projectRoots, ["/Users/x/work/octok-client"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "projectRoots"),
            ["/Users/x/work/octok-client"]
        )
    }

    func testRemovePersistsRoot() {
        let defaults = makeDefaults()
        defaults.set(["/Users/x/work/a", "/Users/x/work/b"], forKey: "projectRoots")
        let store = ProjectRootsStore(defaults: defaults)

        store.remove("/Users/x/work/a")

        XCTAssertEqual(store.projectRoots, ["/Users/x/work/b"])
        XCTAssertEqual(defaults.stringArray(forKey: "projectRoots"), ["/Users/x/work/b"])
    }

    // MARK: 归一与幂等

    /// 尾斜杠归一后与现有根相同:幂等忽略,不产生重复条目。
    func testAddIgnoresDuplicateWithTrailingSlash() {
        let store = ProjectRootsStore(defaults: makeDefaults())
        store.add("/Users/x/work/octok-client")

        store.add("/Users/x/work/octok-client/")

        XCTAssertEqual(store.projectRoots, ["/Users/x/work/octok-client"])
    }

    /// 同一根添加两次:列表与持久化都只留一条。
    func testAddSameRootTwiceKeepsSingleEntry() {
        let defaults = makeDefaults()
        let store = ProjectRootsStore(defaults: defaults)

        store.add("/Users/x/work/octok-client")
        store.add("/Users/x/work/octok-client")

        XCTAssertEqual(store.projectRoots, ["/Users/x/work/octok-client"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "projectRoots"),
            ["/Users/x/work/octok-client"]
        )
    }

    /// 移除不存在的根:安静无操作,列表与持久化不变。
    func testRemoveUnknownRootIsNoOp() {
        let defaults = makeDefaults()
        defaults.set(["/Users/x/work/a"], forKey: "projectRoots")
        let store = ProjectRootsStore(defaults: defaults)

        store.remove("/Users/x/work/never-added")

        XCTAssertEqual(store.projectRoots, ["/Users/x/work/a"])
        XCTAssertEqual(defaults.stringArray(forKey: "projectRoots"), ["/Users/x/work/a"])
    }

    // MARK: 重启往返(round-trip)

    /// 增删后再"重启"(新 store 同 defaults):最终列表原样保留。
    func testRootsSurviveStoreRecreation() {
        let defaults = makeDefaults()
        let first = ProjectRootsStore(defaults: defaults)
        first.add("/Users/x/work/octok-client/")
        first.add("/Users/x/work/vitals")
        first.remove("/Users/x/work/octok-client")

        XCTAssertEqual(ProjectRootsStore(defaults: defaults).projectRoots, ["/Users/x/work/vitals"])
    }
}

@testable import PulseCore
import XCTest

/// cask 收据解析(p4-uninstaller/01)。夹具形状 = 2026-11-03 本机探针实录
/// (brew 7.0.12,bitwarden 收据缩样),顶层混入无关键验证宽松提取。
final class CaskReceiptTests: XCTestCase {
    private func receiptJSON(
        artifacts: String,
        extras: String = "\"homebrew_version\": \"7.0.12\", \"arch\": \"arm64\""
    ) -> Data {
        Data("""
        { \(extras), "uninstall_artifacts": \(artifacts) }
        """.utf8)
    }

    func testParseRealReceiptShape() {
        let data = receiptJSON(artifacts: """
        [ {"uninstall": [{"quit": ["com.bitwarden.desktop", "com.bitwarden.desktop.helper"]}]},
          {"app": ["Bitwarden.app"]},
          {"zap": [{"trash": ["~/Library/Application Support/Bitwarden", "~/Library/Preferences/com.bitwarden.desktop.plist"]}]} ]
        """)
        let receipt = CaskReceipt.parse(caskName: "bitwarden", data: data)
        XCTAssertEqual(receipt?.caskName, "bitwarden")
        XCTAssertEqual(receipt?.artifactAppNames, ["Bitwarden.app"])
        XCTAssertEqual(
            receipt?.zapTrashPaths,
            [
                NSHomeDirectory() + "/Library/Application Support/Bitwarden",
                NSHomeDirectory() + "/Library/Preferences/com.bitwarden.desktop.plist",
            ]
        )
        XCTAssertEqual(receipt?.quitBundleIDs, ["com.bitwarden.desktop", "com.bitwarden.desktop.helper"])
    }

    func testParseReceiptWithoutArtifactsYieldsEmptyProjection() {
        // 老 / 手动塞的收据:目录在 Caskroom = cask 身份成立,但没有可提取声明。
        let data = Data(#"{"homebrew_version": "3.0.0"}"#.utf8)
        let receipt = CaskReceipt.parse(caskName: "oldcask", data: data)
        XCTAssertEqual(receipt, CaskReceipt(caskName: "oldcask"))
    }

    func testParseCorruptJSONReturnsNil() {
        XCTAssertNil(CaskReceipt.parse(caskName: "x", data: Data("not json".utf8)))
    }

    func testZapWithoutTildeStaysLiteral() {
        let data = receiptJSON(artifacts: #"[ {"zap": [{"trash": ["/opt/local/share/thing"]}]} ]"#)
        let receipt = CaskReceipt.parse(caskName: "x", data: data)
        XCTAssertEqual(receipt?.zapTrashPaths, ["/opt/local/share/thing"])
    }

    func testIndexMapsAppNameToCask() throws {
        let receipt = try XCTUnwrap(CaskReceipt.parse(
            caskName: "ghostty",
            data: receiptJSON(artifacts: #"[ {"app": ["Ghostty.app"]} ]"#)
        ))
        XCTAssertEqual(CaskReceiptIndex.build([receipt]), ["Ghostty.app": "ghostty"])
    }

    func testIndexDropsConflictingAppName() {
        // 两个 cask 声明同一 app 名 = 歧义,整名丢弃(GLOSSARY:宁可漏标不误标)。
        let a = CaskReceipt(caskName: "cask-a", artifactAppNames: ["Twin.app"])
        let b = CaskReceipt(caskName: "cask-b", artifactAppNames: ["Twin.app", "Solo.app"])
        let index = CaskReceiptIndex.build([a, b])
        XCTAssertNil(index["Twin.app"])
        XCTAssertEqual(index["Solo.app"], "cask-b")
    }
}

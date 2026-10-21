@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝:KERN_PROCARGS2 缓冲解析(纯逻辑)。
/// 布局口径来自 spec 采集决策与 ps 的既有语义:argc(int32) + execpath + argv[0..argc-1]。
/// 夹具按该布局独立手工构造,验证解析跳过 execpath 后 argv 取满 argc 条。
final class ProcArgsParserTests: XCTestCase {
    /// 按内核布局构造缓冲:小端 int32 argc,后接若干 NUL 结尾字符串。
    private func buffer(argc: Int32, strings: [String]) -> [CChar] {
        var bytes: [CChar] = []
        var littleEndianArgc = argc.littleEndian
        withUnsafeBytes(of: &littleEndianArgc) { raw in
            bytes.append(contentsOf: raw.map { CChar(bitPattern: $0) })
        }
        for string in strings {
            for byte in string.utf8 {
                bytes.append(CChar(bitPattern: byte))
            }
            bytes.append(0)
        }
        return bytes
    }

    func testParsesFullArgvAfterSkippingExecpath() {
        let buf = buffer(argc: 3, strings: ["/usr/local/bin/cargo", "cargo", "build", "--release"])

        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: buf, validLength: buf.count), ["cargo", "build", "--release"])
    }

    func testSingleArgumentProcessYieldsArgvZeroOnly() {
        let buf = buffer(argc: 1, strings: ["/usr/sbin/periodic", "daily"])

        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: buf, validLength: buf.count), ["daily"])
    }

    func testEmptyArgSlotIsConsumedButNotAppended() {
        // 空参数占一个槽位(单个 NUL),不能因此错位读到 envp。
        let buf = buffer(argc: 3, strings: ["/bin/zsh", "-c", "", "echo hi"])

        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: buf, validLength: buf.count), ["-c", "echo hi"])
    }

    func testAlignmentPaddingAfterExecpathIsSkipped() {
        // 内核把 argv 起点按 int 对齐:execpath 后可跟 0~3 个补位 NUL(本机实测如此)。
        let buf = buffer(argc: 1, strings: ["/System/usr/libexec/daemon", "", "", "", "worker"])

        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: buf, validLength: buf.count), ["worker"])
    }

    func testTruncatedBufferReturnsPrefixWithoutCrash() {
        // 4(argc)+ 20(execpath"NUL")+ 6("cargo"NUL)= 30:恰好截在第二条 argv 前。
        let buf = buffer(argc: 3, strings: ["/usr/local/bin/cargo", "cargo", "build", "--release"])
        let truncated = Array(buf.prefix(30))

        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: truncated, validLength: truncated.count), ["cargo"])
    }

    func testZeroOrNegativeArgcYieldsEmptyArgv() {
        let zero = buffer(argc: 0, strings: ["/bin/ls"])
        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: zero, validLength: zero.count), [])

        let negative = buffer(argc: -2, strings: ["/bin/ls"])
        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: negative, validLength: negative.count), [])
    }

    func testTooShortBufferYieldsEmptyArgv() {
        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: [0, 0, 0], validLength: 3), [])
        XCTAssertEqual(ProcArgsParser.parseArgv(buffer: [], validLength: 0), [])
    }
}

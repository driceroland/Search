import Foundation
import JavaScriptCore
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionScriptingTests: XCTestCase {
    func testForwardedFunctionKeepsArgumentsAndResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let path = try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder)
        let source = try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        XCTAssertEqual(context.evaluateScript(source)?.toString(), "clip2")
        XCTAssertEqual(try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder), path)
    }
}

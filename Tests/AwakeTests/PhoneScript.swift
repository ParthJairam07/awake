import JavaScriptCore
import XCTest
@testable import Awake

/// The phone page's pure helpers, run in JavaScriptCore: app.js exports
/// them through `module.exports` and returns before it touches a page.
final class PhoneScript {
    private let context: JSContext

    init() throws {
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("app.js: \(error?.toString() ?? "exception")") }
        context.evaluateScript("var module = { exports: {} };")
        context.evaluateScript(String(decoding: PhoneWebAsset.script.data, as: UTF8.self))
    }

    /// `module.exports.<function>(<json>)`, as JSON text.
    func call(_ function: String, _ json: String) -> String {
        context.evaluateScript("JSON.stringify(module.exports.\(function)(\(json)))")?.toString() ?? ""
    }
}

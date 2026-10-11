import Foundation

@main
struct BridgeTests {
    static var checks = 0
    static let scriptURL = URL(fileURLWithPath: "/test resources/SafariBridge.scpt")
    static let sampleJSON = Data("[[11,1,\"A \\\"quoted\\\" title\",\"https://example.org/a?x=1&y=2\"],[11,2,\"\",\"\"],[27,1,\"Other window\",\"https://example.net\"]]".utf8)

    static func main() throws {
        try listDecoding()
        try actionArguments()
        try defaultPageArguments()
        try defaultPageFailures()
        try serialization()
        try failures()
        try processTransport()
        print("Passed \(checks) bridge checks")
    }

    static func listDecoding() throws {
        let calls = CallRecorder()
        let bridge = SafariBridge(scriptURL: scriptURL, executor: { url, arguments in
            expect(!Thread.isMainThread, "Execute Safari scripts off the main thread")
            calls.append(url: url, arguments: arguments)
            return sampleJSON
        })
        let tabs = try awaitResult { bridge.list(completion: $0) }.get()
        expect(calls.values == [Call(url: scriptURL, arguments: ["list"])], "List uses the compiled script and list argv")
        expect(tabs.count == 3, "Decode multiple windows and blank tabs")
        expect(tabs[0].title == "A \"quoted\" title", "Decode escaped titles without altering them")
        expect(tabs[1] == SafariTab(windowID: 11, index: 2, title: "", url: ""), "Keep blank tabs addressable")
        expect(tabs[2].windowID == 27 && tabs[2].index == 1, "Preserve one-based indices independently per window")

        let emptyBridge = SafariBridge(scriptURL: scriptURL, executor: { _, _ in Data("[]".utf8) })
        try expect(awaitResult { emptyBridge.list(completion: $0) }.get().isEmpty, "An empty Safari session succeeds")
    }

    static func actionArguments() throws {
        let calls = CallRecorder()
        let bridge = SafariBridge(scriptURL: scriptURL, executor: { url, arguments in
            calls.append(url: url, arguments: arguments)
            return Data("ok".utf8)
        })
        let tab = SafariTab(windowID: 42, index: 6, title: "A \"title\"\nnext line", url: "https://example.org/?quote=\"&a=1")
        _ = try awaitResult { bridge.select(tab, completion: $0) }.get()
        let query = "query \"quoted\"\nsecond line; $(echo never)"
        _ = try awaitResult { bridge.open(.search(query), windowID: 42, completion: $0) }.get()
        _ = try awaitResult { bridge.open(.url("https://example.org/a?x=1&y=2"), windowID: 0, completion: $0) }.get()
        expect(calls.values.map(\.arguments) == [
            ["switch", "42", "6", tab.url, tab.title],
            ["search", "42", query],
            ["url", "0", "https://example.org/a?x=1&y=2"]
        ], "Selection and creation pass quotes, newlines and shell characters as literal argv")
    }

    static func defaultPageArguments() throws {
        let calls = CallRecorder()
        let nativeOutput = Data("native-ok".utf8)
        let bridge = SafariBridge(scriptURL: scriptURL, newTabExecutor: {
            expect(!Thread.isMainThread, "The native Safari command runs off the main thread")
            calls.append(url: scriptURL, arguments: ["native-new-tab"])
            return nativeOutput
        }) { url, arguments in
            expect(!Thread.isMainThread, "Window preparation runs off the main thread")
            calls.append(url: url, arguments: arguments)
            return Data(" ok\n".utf8)
        }
        try expect(awaitResult { bridge.open(.defaultPage, windowID: 7, completion: $0) }.get() == nativeOutput,
                   "A target-window action returns native command success, not preparation output")
        try expect(awaitResult { bridge.open(.defaultPage, windowID: 0, completion: $0) }.get() == nativeOutput,
                   "A front-window action returns native command success")
        expect(calls.values == [
            Call(url: scriptURL, arguments: ["prepare-new-tab", "7"]),
            Call(url: scriptURL, arguments: ["native-new-tab"]),
            Call(url: scriptURL, arguments: ["prepare-new-tab", "0"]),
            Call(url: scriptURL, arguments: ["native-new-tab"])
        ], "Each new-tab action prepares its requested window before exactly one native Safari command")
        let preparation = calls.values.filter { $0.arguments.first == "prepare-new-tab" }
        expect(preparation.allSatisfy { $0.arguments.count == 2 }, "Preparation cannot send about:blank or search text as a destination")
    }

    static func defaultPageFailures() throws {
        let deniedCalls = CallRecorder()
        let denied = SafariBridge(scriptURL: scriptURL, newTabExecutor: {
            deniedCalls.append(url: scriptURL, arguments: ["native-new-tab"])
            return Data("unexpected".utf8)
        }) { url, arguments in
            deniedCalls.append(url: url, arguments: arguments)
            throw BridgeError.permission
        }
        expectError(awaitResult { denied.open(.defaultPage, windowID: 7, completion: $0) }, matching: .permission,
                    "A preparation failure is preserved")
        expect(deniedCalls.values == [Call(url: scriptURL, arguments: ["prepare-new-tab", "7"])],
               "Failed window preparation suppresses the native Safari command")

        let malformedCalls = CallRecorder()
        let malformed = SafariBridge(scriptURL: scriptURL, newTabExecutor: {
            malformedCalls.append(url: scriptURL, arguments: ["native-new-tab"])
            return Data("unexpected".utf8)
        }) { url, arguments in
            malformedCalls.append(url: url, arguments: arguments)
            return Data("not-ready".utf8)
        }
        expectError(awaitResult { malformed.open(.defaultPage, windowID: 7, completion: $0) }, matching: .invalidResponse,
                    "Malformed preparation output is rejected before native creation")
        expect(malformedCalls.values == [Call(url: scriptURL, arguments: ["prepare-new-tab", "7"])],
               "An unconfirmed preparation response cannot trigger a native command")

        let nativeCalls = CallRecorder()
        let rejected = SafariBridge(scriptURL: scriptURL, newTabExecutor: {
            nativeCalls.append(url: scriptURL, arguments: ["native-new-tab"])
            throw NativeFixtureError.unavailable
        }) { url, arguments in
            nativeCalls.append(url: url, arguments: arguments)
            return Data("ok".utf8)
        }
        switch awaitResult({ rejected.open(.defaultPage, windowID: 0, completion: $0) }) {
        case .success: fatalError("A failed native command must not appear successful")
        case .failure(let error):
            expect((error as? NativeFixtureError) == .unavailable, "The native command's original error reaches the caller")
        }
        expect(nativeCalls.values == [
            Call(url: scriptURL, arguments: ["prepare-new-tab", "0"]),
            Call(url: scriptURL, arguments: ["native-new-tab"])
        ], "A failed native command is not retried or replaced by URL creation")
    }

    static func serialization() throws {
        let calls = CallRecorder()
        let bridge = SafariBridge(scriptURL: scriptURL, newTabExecutor: {
            calls.append(url: scriptURL, arguments: ["native-new-tab"])
            return Data("ok".utf8)
        }) { url, arguments in
            calls.append(url: url, arguments: arguments)
            Thread.sleep(forTimeInterval: 0.01)
            return arguments == ["list"] ? sampleJSON : Data("ok".utf8)
        }
        let tab = SafariTab(windowID: 1, index: 1, title: "A", url: "https://example.org")
        var completions = [String]()
        bridge.list { _ in completions.append("list") }
        bridge.select(tab) { _ in completions.append("switch") }
        bridge.open(.defaultPage, windowID: 1) { _ in completions.append("new-tab") }
        _ = try awaitResult { bridge.open(.search("last"), windowID: 1, completion: $0) }.get()
        expect(calls.values.map { $0.arguments[0] } == ["list", "switch", "prepare-new-tab", "native-new-tab", "search"],
               "Window preparation and native creation cannot be interleaved with another submitted action")
        expect(completions == ["list", "switch", "new-tab"], "Earlier main-thread callbacks precede the final callback")
    }

    static func failures() throws {
        let malformed = SafariBridge(scriptURL: scriptURL, executor: { _, _ in Data("[[1,2,3,4]]".utf8) })
        expectError(awaitResult { malformed.list(completion: $0) }, matching: .invalidResponse, "Reject malformed tab rows")
        let permission = SafariBridge(scriptURL: scriptURL, executor: { _, _ in throw BridgeError.permission })
        expectError(awaitResult { permission.list(completion: $0) }, matching: .permission, "Forward bridge permission failures")

        expectError(Result { try output(status: 1, errors: "Not authorized (-1743)").validatedData() }, matching: .permission, "Map Safari Automation denial")
        expectError(Result { try output(status: 1, errors: "TAB_SCOUT_STALE").validatedData() }, matching: .staleTab, "Map a closed or moved selected tab")
        expectError(Result { try output(status: 1, errors: "Apple event timed out (-1712)").validatedData() }, matching: .timeout, "Map Safari's Apple-event timeout")
        expectError(Result { try output(status: 0, timedOut: true).validatedData() }, matching: .timeout, "A deadline cannot appear as a successful action")
        expectError(Result { try output(status: 15, signaled: true).validatedData() }, matching: .timeout, "Map an externally terminated process")
        let changed = try Result { try output(status: 1, errors: "TAB_SCOUT_SNAPSHOT_CHANGED").validatedData() }.errorDescription()
        expect(changed == "Safari tabs changed while refreshing. Try again.", "Explain an unstable snapshot without returning mixed rows")
        let hidden = try Result { try output(status: 1, errors: "Private URL: https://secret.example").validatedData() }.errorDescription()
        expect(!hidden.contains("secret.example"), "Do not expose raw Safari diagnostics to the UI")
        try expect(output(data: Data("ok".utf8)).validatedData() == Data("ok".utf8), "Pass successful stdout through unchanged")
    }

    static func processTransport() throws {
        let start = Date()
        let large = try SafariScriptProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/awk"), arguments: [
            "BEGIN { for (i=0; i<20000; i++) print \"failure diagnostic line\" > \"/dev/stderr\"; printf \"[]\"; exit 7 }"
        ], timeout: 5)
        expect(large.data == Data("[]".utf8), "Drain stdout while a failed child fills stderr")
        expect(large.errors.count > 400_000 && large.status == 7 && !large.timedOut, "Drain diagnostics larger than the pipe buffer without deadlocking")
        expect(Date().timeIntervalSince(start) < 5, "A large-error process completes before its deadline")
        let timeout = try SafariScriptProcess.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
        expect(timeout.timedOut && timeout.signaled, "Terminate an unresponsive process at the deadline")
        expectError(Result { try timeout.validatedData() }, matching: .timeout, "Report process deadlines as recoverable bridge timeouts")
    }

    static func output(data: Data = Data(), status: Int32 = 0, errors: String = "", signaled: Bool = false, timedOut: Bool = false) -> SafariScriptProcess.Output {
        SafariScriptProcess.Output(data: data, errors: Data(errors.utf8), status: status, signaled: signaled, timedOut: timedOut)
    }

    static func awaitResult<Value>(_ operation: (@escaping (Result<Value, Error>) -> Void) -> Void) -> Result<Value, Error> {
        var value: Result<Value, Error>?
        operation { result in
            expect(Thread.isMainThread, "Deliver bridge callbacks on the main thread")
            value = result
        }
        let deadline = Date().addingTimeInterval(3)
        while value == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let value else { fatalError("A bridge callback did not arrive") }
        return value
    }

    static func expectError<Value>(_ result: Result<Value, Error>, matching expected: BridgeError, _ message: String) {
        switch result {
        case .success: fatalError(message)
        case .failure(let error): expect(error.localizedDescription == expected.localizedDescription, message)
        }
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        if try !condition() { fatalError(message) }
    }
}

private enum NativeFixtureError: Error, Equatable { case unavailable }

private struct Call: Equatable {
    let url: URL
    let arguments: [String]
}

private final class CallRecorder {
    private let lock = NSLock()
    private var calls = [Call]()

    func append(url: URL, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(url: url, arguments: arguments))
    }

    var values: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private extension Result {
    func errorDescription() throws -> String {
        switch self {
        case .success: throw BridgeError.script("An expected failure succeeded")
        case .failure(let error): return error.localizedDescription
        }
    }
}

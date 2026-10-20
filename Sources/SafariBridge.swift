import Foundation
import Darwin

final class SafariBridge {
    typealias ScriptExecutor = (URL, [String]) throws -> Data
    typealias NewTabExecutor = () throws -> Data

    // Tab-list reads run beside actions, so Enter never waits for a background refresh to finish.
    private let readQueue = DispatchQueue(label: "local.tabscout.safari.read")
    private let actionQueue = DispatchQueue(label: "local.tabscout.safari.action")
    private let scriptURL: URL
    private let newTabExecutor: NewTabExecutor
    private let executor: ScriptExecutor

    init(scriptURL: URL, newTabExecutor: @escaping NewTabExecutor = SafariNativeNewTab.open,
         executor: @escaping ScriptExecutor = SafariScriptProcess.execute) {
        self.scriptURL = scriptURL
        self.newTabExecutor = newTabExecutor
        self.executor = executor
    }

    func list(completion: @escaping (Result<TabInventory, Error>) -> Void) {
        execute(["list"], on: readQueue) { result in completion(result.flatMap { data in Result { try TabInventory.decode(data) } }) }
    }

    func active(completion: @escaping (Result<SafariTab?, Error>) -> Void) {
        execute(["active"], on: readQueue) { result in completion(result.flatMap { data in Result { try TabInventory.decodeActive(data) } }) }
    }

    /// The visible text of `tab`, at most 30,000 characters. Fails as stale when the tab moved or navigated.
    func text(of tab: SafariTab, completion: @escaping (Result<String, Error>) -> Void) {
        execute(["text", String(tab.windowID), String(tab.index), tab.url], on: readQueue) { result in
            completion(result.map { data in
                // osascript ends its output with a newline.
                var text = String(decoding: data, as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }
                return text
            })
        }
    }

    func select(_ tab: SafariTab, completion: @escaping (Result<Data, Error>) -> Void) {
        execute(["switch", String(tab.windowID), String(tab.index), tab.url, tab.title], on: actionQueue, completion: completion)
    }

    /// Opens `destination` in a new tab, or in `blank`, an empty tab on screen, so that no empty tab is left behind.
    /// The script still opens a new tab when `blank` has navigated away meanwhile.
    func open(_ destination: NewTabDestination, windowID: Int, reusing blank: SafariTab? = nil,
              completion: @escaping (Result<Data, Error>) -> Void) {
        let windowID = String(blank?.windowID ?? windowID)
        let reuse = blank.map { [String($0.index), $0.url] } ?? []
        switch destination {
        case .defaultPage:
            if let blank { return select(blank, completion: completion) }
            execute(["prepare-new-tab", windowID], on: actionQueue, after: newTabExecutor, completion: completion)
        case .url(let url): execute(["url", windowID, url] + reuse, on: actionQueue, completion: completion)
        case .search(let query): execute(["search", windowID, query] + reuse, on: actionQueue, completion: completion)
        }
    }

    private func execute(_ arguments: [String], on queue: DispatchQueue, after action: NewTabExecutor? = nil,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        let submitted = DispatchTime.now()
        queue.async { [scriptURL, executor] in
            Timing.log("safari \(arguments[0]) queued", since: submitted)
            let started = DispatchTime.now()
            defer { Timing.log("safari \(arguments[0])", since: started) }
            let result = Result {
                let data = try executor(scriptURL, arguments)
                guard let action else { return data }
                guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                    throw BridgeError.invalidResponse
                }
                return try action()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

enum SafariScriptProcess {
    struct Output {
        let data: Data
        let errors: Data
        let status: Int32
        let signaled: Bool
        let timedOut: Bool

        func validatedData() throws -> Data {
            if timedOut { throw BridgeError.timeout }
            guard status == 0 else {
                let message = String(decoding: errors, as: UTF8.self)
                if message.contains("-1743") { throw BridgeError.permission }
                if message.contains("TAB_SCOUT_STALE") { throw BridgeError.staleTab }
                if message.contains("TAB_SCOUT_SNAPSHOT_CHANGED") {
                    throw BridgeError.script("Safari tabs changed while refreshing. Try again.")
                }
                if message.contains("-1712") || signaled { throw BridgeError.timeout }
                throw BridgeError.script("Safari could not complete this action. Try refreshing the tab list.")
            }
            return data
        }
    }

    static func execute(scriptURL: URL, arguments: [String]) throws -> Data {
        try run(executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [scriptURL.path] + arguments).validatedData()
    }

    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval = 60) throws -> Output {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let outputData = LockedValue(Data())
        let errorData = LockedValue(Data())
        let didTimeOut = LockedValue(false)
        let readers = DispatchGroup()
        // Both pipes must drain while the child runs, including on failure.
        readers.enter()
        DispatchQueue.global().async {
            outputData.set(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            didTimeOut.set(true)
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        readers.wait()
        return Output(data: outputData.get(), errors: errorData.get(), status: process.terminationStatus,
                      signaled: process.terminationReason == .uncaughtSignal, timedOut: didTimeOut.get())
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

import Darwin
import Foundation

/// Covers the app's end of the link to Tab Scout's extension in Firefox and Zen, with stand-in extensions on a
/// private socket; no browser is touched. FirefoxLinkTests <path to the extension's manifest.json>
@main
struct FirefoxLinkTests {
    static var checks = 0

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        manifests(extensionManifest: URL(fileURLWithPath: CommandLine.arguments[1]))
        browsers()
        answers()
        link()
        print("Passed \(checks) Firefox link checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func manifests(extensionManifest: URL) {
        let helper = URL(fileURLWithPath: "/Applications/Tab Scout.app/Contents/MacOS/TabScoutFirefoxHost")
        let host = (try? JSONSerialization.jsonObject(with: FirefoxHostManifest.contents(helper: helper))) as? [String: Any]
        expect(host?["name"] as? String == NativeMessage.firefoxHostName && host?["path"] as? String == helper.path
               && host?["type"] as? String == "stdio"
               && host?["allowed_extensions"] as? [String] == [NativeMessage.firefoxExtensionID],
               "Firefox may start the helper only for Tab Scout's extension")
        expect(FirefoxHostManifest.url.path.hasSuffix("/Library/Application Support/Mozilla/NativeMessagingHosts/local.tabscout.firefox.json"),
               "The helper is announced where Firefox and the browsers built on it look")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabScoutFirefoxHosts-\(getpid())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("NativeMessagingHosts/host.json")
        expect((try? FirefoxHostManifest.install(helper: helper, at: installed)) != nil
               && (try? Data(contentsOf: installed)) == FirefoxHostManifest.contents(helper: helper), "Installing creates its folder")
        // A file that already says the same is left alone, so launching Tab Scout does not rewrite it every time.
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: installed.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: installed.deletingLastPathComponent().path)
        expect((try? FirefoxHostManifest.install(helper: helper, at: installed)) != nil, "An up-to-date file is not written again")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.deletingLastPathComponent().path)
        let moved = URL(fileURLWithPath: "/Users/someone/Tab Scout.app/Contents/MacOS/TabScoutFirefoxHost")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installed.path)
        expect((try? FirefoxHostManifest.install(helper: moved, at: installed)) != nil
               && (try? Data(contentsOf: installed)) == FirefoxHostManifest.contents(helper: moved), "A file naming another copy of the app is replaced")

        guard let data = try? Data(contentsOf: extensionManifest),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let gecko = (manifest["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any] else {
            fatalError("Unreadable extension manifest")
        }
        expect(gecko["id"] as? String == NativeMessage.firefoxExtensionID, "The extension's ID is the one the helper allows")
        expect(manifest["version"] as? String == FirefoxExtension.version, "Tab Scout knows which version of the extension it carries")
        expect(FirefoxExtension.isSigned(Data("PK…META-INF/mozilla.rsa…".utf8)) && !FirefoxExtension.isSigned(Data("PK…manifest.json…background.js".utf8)),
               "A package with Mozilla's signature inside is told from one without")
    }

    static func browsers() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TabScoutBrowsers-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, _ bundleID: String) -> URL {
            let contents = root.appendingPathComponent(name + ".app/Contents")
            try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return contents.appendingPathComponent("MacOS/" + name.lowercased())
        }
        expect(FirefoxLink.browser(at: app("Firefox", "org.mozilla.firefox")) == .firefox
               && FirefoxLink.browser(at: app("Zen Browser", "app.zen-browser.zen")) == .zen,
               "The program that started a helper names its browser by the app it is inside")
        expect(FirefoxLink.browser(at: app("Chrome", "com.google.Chrome")) == nil && FirefoxLink.browser(at: app("Other", "org.example.other")) == nil
               && FirefoxLink.browser(at: URL(fileURLWithPath: "/bin/sh")) == nil,
               "Chrome, which has its own link, other apps and plain programs are no browser to serve here")
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fatalError("socketpair failed") }
        defer { close(pair[0]); close(pair[1]) }
        expect(FirefoxLink.browser(startingHelperAt: pair[0]) == nil && FirefoxLink.browser(startingHelperAt: -1) == nil,
               "A helper started by something other than a browser, like this test, is turned away")
    }

    static func answers() {
        func text(_ result: Result<Data, Error>) -> String? { (try? result.get()).map { String(decoding: $0, as: UTF8.self) } }
        func failure(_ result: Result<Data, Error>) -> BridgeError? {
            if case .failure(let error) = result { return error as? BridgeError }
            return nil
        }
        expect(text(FirefoxLink.answer(.success(["id": 1, "result": "[[3,1,\"A\",\"a\",true]]"]), browser: .zen)) == "[[3,1,\"A\",\"a\",true]]",
               "A command's result is passed on as the browser's script would print it")
        expect(failure(FirefoxLink.answer(.success(["error": "TAB_SCOUT_STALE"]), browser: .zen)) == .staleTab, "A tab that moved is reported as stale")
        expect(failure(FirefoxLink.answer(.success(["error": "unknown request"]), browser: .zen))
               == .script("Tab Scout's extension in Zen is out of date. Add it again in Settings > Setup."),
               "An extension that does not know a command is out of date")
        expect(failure(FirefoxLink.answer(.success(["error": "Illegal URL: file:///secret"]), browser: .firefox))
               == .script("Firefox could not complete this action. Try refreshing the tab list."),
               "The browser's own refusal is reported without its details, which can hold an address")
        expect(failure(FirefoxLink.answer(.failure(ExtensionLink.Failure.timeout), browser: .firefox)) == .timeout
               && failure(FirefoxLink.answer(.failure(ExtensionLink.Failure.notConnected), browser: .firefox)) == .extensionMissing,
               "An extension that is slow or gone is reported as such")
        expect(BridgeError.extensionMissing.message(for: .zen) == "Zen needs Tab Scout's extension. Add it in Tab Scout's Settings > Setup.",
               "A browser without the extension says where to add it")
    }

    /// A stand-in for a browser's extension behind its helper: greets, then answers each request with `answer`.
    final class FakeExtension {
        let socket: Int32
        private var requests: [[String: Any]] = []
        private let lock = NSLock()

        init?(at url: URL, answer: @escaping ([String: Any]) -> [String: Any]?) {
            socket = NativeMessage.connect(to: url)
            guard socket >= 0, NativeMessage.read(from: socket) != nil else { return nil }
            Thread.detachNewThread { [socket, lock] in
                while let data = NativeMessage.read(from: socket),
                      let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    lock.lock()
                    self.requests.append(request)
                    lock.unlock()
                    guard var reply = answer(request) else { continue }
                    reply["id"] = request["id"]
                    self.send(reply)
                }
            }
        }

        func send(_ message: [String: Any]) {
            guard let encoded = try? JSONSerialization.data(withJSONObject: message) else { return }
            lock.lock()
            defer { lock.unlock() }
            _ = NativeMessage.write(NativeMessage.frame(encoded), to: socket)
        }

        var received: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    static func wait<Value>(_ value: () -> Value?) -> Value {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = value() { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        fatalError("Timed out")
    }

    static func error(_ work: () throws -> Data) -> BridgeError? {
        do { _ = try work() } catch { return error as? BridgeError }
        return nil
    }

    static func link() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tabscout-ff-\(getpid())/firefox.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Which browser each stand-in's helper was started by, in the order they connect.
        var arriving: [FirefoxLink.Peer?] = []
        let link = FirefoxLink(socketURL: url, verifyPeer: { _ in true }, identify: { _ in arriving.isEmpty ? nil : arriving.removeFirst() })
        var changes = 0
        var events: [String] = []
        link.onChange = { changes += 1 }
        link.onEvent = { browser, event in events.append(browser.rawValue + " " + event) }
        expect(error { try link.run(["list"], in: .firefox) } == .extensionMissing, "Nothing is connected before the link starts")
        link.start()

        let stranger = NativeMessage.connect(to: url)
        expect(stranger >= 0 && NativeMessage.read(from: stranger) == nil, "A helper no browser started is turned away without a greeting")
        close(stranger)
        expect(link.connectedBrowsers.isEmpty, "A helper turned away is no browser")

        func rows(_ title: String) -> String { "[[3,1,\"\(title)\",\"https://\(title.lowercased()).example/\",true]]" }
        func stand(_ rows: String, version: String?) -> ([String: Any]) -> [String: Any]? {
            { request in
                switch (request["type"] as? String, request["command"] as? String) {
                case ("version", _): return version.map { ["version": $0] } ?? ["error": "unknown request"]
                case ("bridge", "list"): return ["result": rows]
                case ("bridge", "switch"): return ["error": "TAB_SCOUT_STALE"]
                case ("bridge", "text"): return ["error": "unknown request"]
                case ("bridge", "url"): return ["error": "Illegal URL"]
                case ("bridge", "slow"): return nil
                case ("mute", _): return ["muted": 1, "unmuted": 0]
                default: return ["error": "unknown request"]
                }
            }
        }
        arriving = [FirefoxLink.Peer(browser: .firefox, process: 100)]
        guard let firefox = FakeExtension(at: url, answer: stand(rows("Fox"), version: FirefoxExtension.version)) else { fatalError("The Firefox stand-in could not connect") }
        arriving = [FirefoxLink.Peer(browser: .zen, process: 200)]
        guard let zen = FakeExtension(at: url, answer: stand(rows("Zen"), version: nil)) else { fatalError("The Zen stand-in could not connect") }
        expect(wait { link.connectedBrowsers == [.firefox, .zen] ? true : nil }, "Each browser whose extension connected is served")
        expect(wait { changes >= 2 ? true : nil }, "The app hears when an extension connects")

        expect((try? link.run(["list"], in: .firefox)).map { String(decoding: $0, as: UTF8.self) } == rows("Fox")
               && (try? link.run(["list"], in: .zen)).map { String(decoding: $0, as: UTF8.self) } == rows("Zen"),
               "A command goes to the browser it is meant for and its answer comes back as a script's output")
        let listed = firefox.received.first { $0["command"] as? String == "list" }
        expect(listed?["type"] as? String == "bridge" && (listed?["args"] as? [String]) == [] && listed?["id"] as? Int != nil,
               "A command travels with its name and arguments, and a number for its answer")
        expect(error { try link.run(["switch", "3", "1", "https://fox.example/", "Fox"], in: .firefox) } == .staleTab, "A stale tab stays a stale tab")
        expect((firefox.received.first { $0["command"] as? String == "switch" }?["args"] as? [String]) == ["3", "1", "https://fox.example/", "Fox"],
               "Arguments arrive as the scripts take them")
        expect(error { try link.run(["text", "3", "1", "u"], in: .firefox) } == .script("Tab Scout's extension in Firefox is out of date. Add it again in Settings > Setup.")
               && error { try link.run(["url", "3", "file:///x"], in: .firefox) } == .script("Firefox could not complete this action. Try refreshing the tab list."),
               "What the extension does not know or the browser refuses is said plainly")
        expect(error { try link.run(["slow"], in: .firefox, timeout: 0.3) } == .timeout, "An extension that never answers runs out of time")
        expect(error { try link.run(["list"], in: .chrome) } == .extensionMissing && error { try link.run([], in: .zen) } == .extensionMissing,
               "A browser with no extension here, or no command at all, is not asked")

        expect(wait { link.versions(in: .firefox) == [FirefoxExtension.version] && link.versions(in: .zen) == [""] ? true : nil },
               "Each extension says its version when it connects; one too old to say counts as outdated")

        zen.send(["type": "event", "event": "focus"])
        firefox.send(["type": "event", "event": "tabs"])
        firefox.send(["type": "something else"])
        expect(wait { events.count == 2 ? true : nil } && Set(events) == ["zen focus", "firefox tabs"], "An extension's news reaches the app with its browser")

        var muted: Result<[String: Any], Error>?
        link.perform("mute", in: .firefox) { muted = $0 }
        expect((try? wait { muted }.get())?["muted"] as? Int == 1, "The browser's extension does what is asked and answers")
        var refused: Result<[String: Any], Error>?
        link.perform("group", in: .zen) { refused = $0 }
        if case .failure(let failure) = wait({ refused }) {
            expect(failure as? BridgeError == .script("Tab Scout's extension in Zen is out of date. Add it again in Settings > Setup."),
                   "A request the extension does not know is not taken for done")
        } else {
            fatalError("An unknown request succeeded")
        }

        // Firefox runs once per profile, each copy with its own extension and its own window numbers.
        arriving = [FirefoxLink.Peer(browser: .firefox, process: 300)]
        guard let second = FakeExtension(at: url, answer: stand(rows("Second"), version: FirefoxExtension.version)) else { fatalError("The second stand-in could not connect") }
        _ = second
        func listedNow() -> String? { (try? link.run(["list"], in: .firefox)).map { String(decoding: $0, as: UTF8.self) } }
        expect(wait { link.versions(in: .firefox).count == 2 ? true : nil } && listedNow() == rows("Fox"), "Without a copy in front, the first to connect is asked")
        link.noteFront(process: 300)
        expect(listedNow() == rows("Second"), "The copy in front is the one asked")
        link.noteFront(process: 999)
        expect(listedNow() == rows("Second"), "With another app in front, the copy last in front is still asked")
        link.noteFront(process: 100)
        expect(listedNow() == rows("Fox"), "Back in front, the first copy is asked again")

        // Shutting down, unlike closing, also wakes the stand-in's own blocked read.
        shutdown(zen.socket, SHUT_RDWR)
        expect(wait { link.connectedBrowsers == [.firefox] ? true : nil }, "A browser whose extension went away is no longer served")
        expect(error { try link.run(["list"], in: .zen) } == .extensionMissing, "Its tabs can no longer be asked for")

        link.stop()
        expect(!FileManager.default.fileExists(atPath: url.path) && NativeMessage.connect(to: url) < 0, "Stopping removes the socket")
    }
}

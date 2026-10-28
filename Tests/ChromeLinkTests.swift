import CryptoKit
import Darwin
import Foundation

/// Covers the app's end of the Chrome extension link with stand-in extensions on a private socket; Chrome is not
/// touched. ChromeLinkTests <path to the extension's manifest.json>
@main
struct ChromeLinkTests {
    static var checks = 0

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        frames()
        signatures()
        manifests(extensionManifest: URL(fileURLWithPath: CommandLine.arguments[1]))
        link()
        print("Passed \(checks) Chrome link checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func frames() {
        let first = Data(#"{"id":1}"#.utf8)
        let second = Data(#"{"id":2,"tabs":[]}"#.utf8)
        var buffer = NativeMessage.frame(first) + NativeMessage.frame(second).prefix(7)
        expect(NativeMessage.messages(from: &buffer) == [first] && buffer.count == 7, "A partial frame waits for the rest")
        buffer += NativeMessage.frame(second).dropFirst(7)
        expect(NativeMessage.messages(from: &buffer) == [second] && buffer.isEmpty, "The rest completes it")
        var oversized = Data([0, 0, 0, 1]) + Data(repeating: 0, count: 10)
        expect(NativeMessage.messages(from: &oversized) == nil, "A frame over the limit ends the connection")

        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fatalError("socketpair failed") }
        expect(NativeMessage.write(NativeMessage.frame(first), to: pair[0]) && NativeMessage.read(from: pair[1]) == first,
               "A written message reads back whole")
        close(pair[0])
        expect(NativeMessage.read(from: pair[1]) == nil, "The end of the stream reads as nothing")
        close(pair[1])
        expect(NativeMessage.address(URL(fileURLWithPath: "/" + String(repeating: "x", count: 200))) == nil,
               "A socket path too long for the system is refused")
    }

    static func signatures() {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fatalError("socketpair failed") }
        defer { close(pair[0]); close(pair[1]) }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        expect(CodeIdentity.peer(of: pair[0], isSignedLike: me), "The process at the other end matches its own code")
        expect(!CodeIdentity.peer(of: pair[0], isSignedLike: URL(fileURLWithPath: "/bin/ls")), "Other code does not match")
        expect(!CodeIdentity.peer(of: -1, isSignedLike: me), "A closed socket matches nothing")
    }

    static func manifests(extensionManifest: URL) {
        let helper = URL(fileURLWithPath: "/Applications/Tab Scout.app/Contents/MacOS/TabScoutChromeHost")
        let host = (try? JSONSerialization.jsonObject(with: ChromeHostManifest.contents(helper: helper))) as? [String: Any]
        expect(host?["name"] as? String == NativeMessage.hostName && host?["path"] as? String == helper.path
               && host?["type"] as? String == "stdio"
               && host?["allowed_origins"] as? [String] == ["chrome-extension://\(NativeMessage.extensionID)/"],
               "Chrome may start the helper only for Tab Scout's extension")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabScoutHosts-\(getpid())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("NativeMessagingHosts/host.json")
        expect((try? ChromeHostManifest.install(helper: helper, at: installed)) != nil
               && (try? Data(contentsOf: installed)) == ChromeHostManifest.contents(helper: helper), "Installing creates its folder")

        guard let data = try? Data(contentsOf: extensionManifest),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (manifest["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else { fatalError("Unreadable extension manifest") }
        // Chrome's extension ID: the first 16 bytes of the key's SHA-256, each hex digit written as a to p.
        let id = SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
            .map { String(UnicodeScalar(UInt8(97) + UInt8(String($0), radix: 16)!)) }.joined()
        expect(id == NativeMessage.extensionID, "The extension's key gives the ID the helper allows")
        let permissions = manifest["permissions"] as? [String] ?? []
        expect(Set(permissions) == ["tabs", "tabGroups", "nativeMessaging", "alarms"], "The extension asks only for what it uses")
    }

    /// A stand-in for one profile's extension behind its helper: greets, then answers each request with `answer`.
    final class FakeExtension {
        let socket: Int32
        var requests: [[String: Any]] = []
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
                    if let encoded = try? JSONSerialization.data(withJSONObject: reply) {
                        _ = NativeMessage.write(NativeMessage.frame(encoded), to: socket)
                    }
                }
            }
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

    static func tabs(_ link: ChromeExtensionLink, window: Int, timeout: TimeInterval = 2) -> Result<ChromeExtensionLink.Window, Error> {
        var result: Result<ChromeExtensionLink.Window, Error>?
        link.tabs(inWindow: window, timeout: timeout) { result = $0 }
        return wait { result }
    }

    static func error(_ result: Result<ChromeExtensionLink.Window, Error>) -> ChromeExtensionLink.LinkError? {
        if case .failure(let error) = result { return error as? ChromeExtensionLink.LinkError }
        return nil
    }

    static func link() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tabscout-\(getpid())/chrome.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var allow = true
        let link = ChromeExtensionLink(socketURL: url, verifyPeer: { _ in allow })
        expect(error(tabs(link, window: 7)) == .notConnected, "Nothing is connected before the link starts")
        link.start()

        allow = false
        let refused = NativeMessage.connect(to: url)
        expect(refused >= 0 && NativeMessage.read(from: refused) == nil, "A process that is not the helper is turned away without a greeting")
        close(refused)
        expect(link.connectedProfiles == 0, "A process turned away is not counted as a profile")
        allow = true

        let tabList: [[String: Any]] = [["id": 41, "title": "Kayak", "url": "https://kayak.com/", "pinned": false, "grouped": false],
                                        ["id": 42, "title": "Pinned", "url": "https://mail.example/", "pinned": true, "grouped": false],
                                        ["title": "No id"]]
        guard let otherProfile = FakeExtension(at: url, answer: { _ in ["error": "no-window"] }),
              let profile = FakeExtension(at: url, answer: { request in
                  switch request["type"] as? String {
                  case "tabs": return request["windowId"] as? Int == 7 ? ["tabs": tabList] : ["error": "no-window"]
                  case "group": return ["grouped": (request["groups"] as? [Any])?.count ?? 0]
                  default: return nil
                  }
              }) else { fatalError("The stand-in extensions could not connect") }
        expect(link.connectedProfiles == 2, "Each connected profile is counted, which the setup window shows")

        let listed = tabs(link, window: 7)
        guard case .success(let window) = listed else { fatalError("The profile with the window did not list it: \(listed)") }
        expect(window.id == 7 && window.tabs == [GroupableTab(id: 41, title: "Kayak", url: "https://kayak.com/", pinned: false, grouped: false),
                                                 GroupableTab(id: 42, title: "Pinned", url: "https://mail.example/", pinned: true, grouped: false)],
               "The profile that has the window lists its tabs; entries without an id are skipped")
        expect(error(tabs(link, window: 8)) == .windowNotFound, "A window no connected profile has is reported as such")

        var made: Result<Int, Error>?
        link.group([PlannedGroup(title: "Trip", tabIDs: [41, 43]), PlannedGroup(title: "Work", tabIDs: [44, 45])], in: window) { made = $0 }
        expect((try? wait { made }.get()) == 2, "The listing profile makes the groups")
        let request = wait { profile.received.first { $0["type"] as? String == "group" } }
        let sent = request["groups"] as? [[String: Any]]
        expect(request["windowId"] as? Int == 7 && sent?.first?["title"] as? String == "Trip" && sent?.first?["tabIds"] as? [Int] == [41, 43],
               "Groups go with their names and tabs")
        expect(!otherProfile.received.contains { $0["type"] as? String == "group" }, "Only the window's profile is asked to group")

        var asked: [Int: Int]?
        link.owners(of: [7, 8]) { asked = $0 }
        let owners = wait { asked }
        expect(owners[7].map { link.connectionIDs.contains($0) } == true && owners[8] == ChromeExtensionLink.nobody,
               "The profile that sees a window owns it, by its connection; a window no profile sees has no owner")

        guard let silent = FakeExtension(at: url, answer: { _ in nil }) else { fatalError("The silent stand-in could not connect") }
        _ = silent
        expect(error(tabs(link, window: 8, timeout: 0.3)) == .timeout, "A profile that never answers runs out of time")
        expect((try? tabs(link, window: 7, timeout: 0.3).get())?.tabs.count == 2, "A silent profile does not hold up the one that answers")
        var partly: [Int: Int]?
        link.owners(of: [7, 8], timeout: 0.3) { partly = $0 }
        let unsure = wait { partly }
        expect(unsure[7] == owners[7] && unsure[8] == nil, "A window a silent profile did not answer about is left out, as it may be that profile's")

        // Shutting down, unlike closing, also wakes the stand-in's own blocked read.
        shutdown(profile.socket, SHUT_RDWR)
        var dropped: Result<Int, Error>?
        link.group([PlannedGroup(title: "Trip", tabIDs: [41, 42])], in: window) { dropped = $0 }
        if case .failure(let failure) = wait({ dropped }) {
            expect(failure as? ChromeExtensionLink.LinkError == .notConnected, "A profile that went away cannot group")
        } else {
            fatalError("Grouping through a closed connection succeeded")
        }
        expect(wait { link.connectedProfiles == 2 ? true : nil }, "A profile that went away is no longer counted")

        link.stop()
        expect(!FileManager.default.fileExists(atPath: url.path) && NativeMessage.connect(to: url) < 0, "Stopping removes the socket")
    }
}

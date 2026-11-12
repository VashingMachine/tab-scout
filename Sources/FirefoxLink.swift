import Darwin
import Foundation

/// Tab Scout's extension in Firefox and the browsers built on it, such as Zen, one copy per running browser. These
/// browsers offer other apps no scripting for tabs, so their tabs are read and changed through the extension, with
/// the commands Tab Scout's Safari and Chrome scripts take. The browser starts TabScoutFirefoxHost for the
/// extension; the helper connects to the app's socket, as ExtensionLink describes, and the browser that started
/// the helper is the one whose tabs its extension has.
final class FirefoxLink {
    /// The browser that started a helper.
    struct Peer: Equatable {
        let browser: Browser
        let process: pid_t
    }

    private let link: ExtensionLink
    private let identify: (Int32) -> Peer?
    // Owned by the link's queue.
    private var peers: [Int: Peer] = [:]
    private var versions: [Int: String] = [:]
    private var frontProcess: pid_t = 0
    /// The copy last in front of each browser, when the browser runs more than once, as Firefox does per profile.
    private var preferred: [Browser: Int] = [:]
    /// Called on the main queue when an extension connects, leaves, or says which version it is.
    var onChange: (() -> Void)?
    /// Called on the main queue when a browser's extension says its tab on screen ("focus") or its tabs ("tabs") changed.
    var onEvent: ((Browser, String) -> Void)?

    /// `verifyPeer` decides whether a connecting process is Tab Scout's helper, by default the one in this app's
    /// bundle; `identify` names the browser that started it.
    init(socketURL: URL = NativeMessage.firefoxSocketURL, verifyPeer: ((Int32) -> Bool)? = nil,
         identify: @escaping (Int32) -> Peer? = FirefoxLink.browser(startingHelperAt:)) {
        let helper = Bundle.main.url(forAuxiliaryExecutable: "TabScoutFirefoxHost")
        link = ExtensionLink(name: "Firefox", socketURL: socketURL,
                             verifyPeer: verifyPeer ?? { socket in helper.map { CodeIdentity.peer(of: socket, isSignedLike: $0) } ?? false })
        self.identify = identify
    }

    func start() {
        link.onConnect = { [weak self] id, socket in
            guard let self, let peer = self.identify(socket) else { return false }
            self.peers[id] = peer
            // Asked once the connection is in place. An extension from before the request says nothing useful, and
            // then counts as outdated.
            self.link.queue.async {
                self.link.request(["type": "version"], on: id, timeout: 5) { result in
                    guard self.peers[id] != nil else { return }
                    self.versions[id] = (try? result.get())?["version"] as? String ?? ""
                    self.changed()
                }
            }
            self.changed()
            return true
        }
        link.onDisconnect = { [weak self] id in
            guard let self else { return }
            self.peers[id] = nil
            self.versions[id] = nil
            self.changed()
        }
        link.onMessage = { [weak self] id, message in
            guard let self, message["type"] as? String == "event", let event = message["event"] as? String,
                  let browser = self.peers[id]?.browser else { return }
            DispatchQueue.main.async { self.onEvent?(browser, event) }
        }
        link.start()
    }

    func stop() { link.stop() }

    /// The browsers whose extension is connected now. Not for use inside `onChange`'s caller's queue; main is fine.
    var connectedBrowsers: Set<Browser> {
        link.queue.sync { Set(link.connected.compactMap { peers[$0]?.browser }) }
    }

    /// The versions of `browser`'s connected extensions that have said theirs; empty text for one too old to say.
    func versions(in browser: Browser) -> [String] {
        link.queue.sync { link.connected.filter { peers[$0]?.browser == browser }.compactMap { versions[$0] } }
    }

    /// Notes which process is in front, so a browser running more than once is asked about the copy on screen.
    func noteFront(process: pid_t) {
        link.queue.async { self.frontProcess = process }
    }

    /// Runs one command of Tab Scout's browser scripts in `browser` and waits for its answer, as running a script
    /// does. Never called on the main thread.
    func run(_ arguments: [String], in browser: Browser, timeout: TimeInterval = 10) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error> = .failure(BridgeError.timeout)
        link.queue.async { [self] in
            guard let command = arguments.first, let connection = connection(for: browser) else {
                outcome = .failure(link.startError.map { BridgeError.script("Tab Scout cannot reach its \(browser.name) extension: \($0)") }
                                   ?? BridgeError.extensionMissing)
                done.signal()
                return
            }
            link.request(["type": "bridge", "command": command, "args": Array(arguments.dropFirst())], on: connection, timeout: timeout) { result in
                outcome = Self.answer(result, browser: browser)
                done.signal()
            }
        }
        done.wait()
        return try outcome.get()
    }

    /// Has `browser`'s extension do `type`, such as "mute", and answers its reply on the main queue.
    func perform(_ type: String, in browser: Browser, timeout: TimeInterval = 5,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        link.queue.async { [self] in
            let finish = { (result: Result<[String: Any], Error>) in DispatchQueue.main.async { completion(result) } }
            guard let connection = connection(for: browser) else { return finish(.failure(BridgeError.extensionMissing)) }
            link.request(["type": type], on: connection, timeout: timeout) { result in
                switch result {
                case .success(let reply) where reply["error"] == nil: finish(.success(reply))
                default: finish(Self.answer(result, browser: browser).map { _ in [:] })
                }
            }
        }
    }

    /// What a reply means for the bridge: the command's output, or why there is none.
    static func answer(_ result: Result<[String: Any], Error>, browser: Browser) -> Result<Data, Error> {
        switch result {
        case .success(let reply):
            if let text = reply["result"] as? String { return .success(Data(text.utf8)) }
            switch reply["error"] as? String {
            case "TAB_SCOUT_STALE"?: return .failure(BridgeError.staleTab)
            // An extension from before the command existed does not know it.
            case "unknown request"?:
                return .failure(BridgeError.script("Tab Scout's extension in \(browser.name) is out of date. Add it again in Settings > Setup."))
            default: return .failure(BridgeError.script("\(browser.name) could not complete this action. Try refreshing the tab list."))
            }
        case .failure(let error):
            switch error as? ExtensionLink.Failure {
            case .timeout?: return .failure(BridgeError.timeout)
            case .unavailable(let reason)?: return .failure(BridgeError.script("Tab Scout cannot reach its \(browser.name) extension: \(reason)"))
            default: return .failure(BridgeError.extensionMissing)
            }
        }
    }

    // MARK: - On the link's queue

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// The copy of `browser` to ask: the one in front, else the one last in front, else the first that connected.
    private func connection(for browser: Browser) -> Int? {
        let own = link.connected.filter { peers[$0]?.browser == browser }.sorted()
        if let inFront = own.first(where: { peers[$0]?.process == frontProcess }) { preferred[browser] = inFront }
        if let kept = preferred[browser], own.contains(kept) { return kept }
        return own.first
    }

    /// The browser that started the helper at the other end of `socket`: the helper's parent process, when it is
    /// one of the browsers Tab Scout reaches through its extension.
    static func browser(startingHelperAt socket: Int32) -> Peer? {
        var helper: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &helper, &length) == 0, helper > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(helper, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(parent, &path, UInt32(path.count)) > 0 else { return nil }
        return browser(at: URL(fileURLWithPath: String(cString: path))).map { Peer(browser: $0, process: parent) }
    }

    /// The browser whose program is at `executable`, such as /Applications/Firefox.app/Contents/MacOS/firefox.
    static func browser(at executable: URL) -> Browser? {
        var bundle = executable
        while bundle.pathComponents.count > 1 && bundle.pathExtension != "app" { bundle.deleteLastPathComponent() }
        guard let browser = Browser(bundleID: Bundle(url: bundle)?.bundleIdentifier), browser.usesExtension else { return nil }
        return browser
    }
}

/// Lets Firefox start TabScoutFirefoxHost for Tab Scout's extension. Firefox and the browsers built on it read the
/// same folder, so one file serves them all.
enum FirefoxHostManifest {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mozilla/NativeMessagingHosts/\(NativeMessage.firefoxHostName).json")
    }

    static func contents(helper: URL) -> Data {
        let manifest: [String: Any] = [
            "name": NativeMessage.firefoxHostName,
            "description": "Tab Scout",
            "path": helper.path,
            "type": "stdio",
            "allowed_extensions": [NativeMessage.firefoxExtensionID]
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes the file unless it already says the same, as after Tab Scout moved or was rebuilt elsewhere.
    static func install(helper: URL, at url: URL = url) throws {
        let wanted = contents(helper: helper)
        if (try? Data(contentsOf: url)) == wanted { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wanted.write(to: url, options: .atomic)
    }
}

/// Tab Scout's extension for Firefox and the browsers built on it, as packaged inside Tab Scout.app.
enum FirefoxExtension {
    /// The version in the extension's manifest.json. A connected extension that says another is offered again.
    static let version = "1.0"

    /// Mozilla's signature is a file of this name inside the package. Firefox installs no extension without one;
    /// Zen does once its xpinstall.signatures.required setting is turned off.
    static func isSigned(_ package: Data) -> Bool {
        package.range(of: Data("META-INF/mozilla.rsa".utf8)) != nil
    }
}

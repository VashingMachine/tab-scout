import Foundation

/// Tab Scout's extension in each Chrome profile that has it. Chrome makes tab groups only for extensions, so the
/// app asks the extension for a window's tabs and has it group them. Chrome starts TabScoutChromeHost for the
/// extension; the helper connects to the app's socket and passes messages on, as ExtensionLink describes.
final class ChromeExtensionLink {
    enum LinkError: LocalizedError, Equatable {
        case unavailable(String)
        case notConnected
        case windowNotFound
        case refused(String)
        case timeout
        /// The extension in Chrome is older than this Tab Scout and does not know the request.
        case outdated

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Tab Scout cannot reach its Chrome extension: \(reason)"
            case .notConnected: return "Add Tab Scout's extension to Chrome to group tabs."
            case .windowNotFound: return "This Chrome profile does not have Tab Scout's extension."
            case .refused(let reason): return "Chrome could not group the tabs: \(reason)"
            case .timeout: return "Tab Scout's Chrome extension did not answer. Try again."
            case .outdated: return "Reload Tab Scout's extension on chrome://extensions, or restart Chrome, to use this command."
            }
        }
    }

    /// One Chrome window's tabs, from the extension of the profile the window belongs to.
    struct Window {
        let id: Int
        let tabs: [GroupableTab]
        fileprivate let connection: Int
    }

    private let link: ExtensionLink
    private var queue: DispatchQueue { link.queue }

    /// `verifyPeer` decides whether a connecting process may talk to the extension; by default it must be the
    /// helper in this app's bundle.
    init(socketURL: URL = NativeMessage.socketURL, verifyPeer: ((Int32) -> Bool)? = nil) {
        let helper = Bundle.main.url(forAuxiliaryExecutable: "TabScoutChromeHost")
        link = ExtensionLink(name: "Chrome", socketURL: socketURL,
                             verifyPeer: verifyPeer ?? { socket in helper.map { CodeIdentity.peer(of: socket, isSignedLike: $0) } ?? false })
    }

    /// Listens for helpers. A failure is reported by the next request instead.
    func start() { link.start() }

    /// How many Chrome profiles' extensions are connected now. Each connects while Chrome runs.
    var connectedProfiles: Int { link.connectionIDs.count }

    /// One per connected profile; a profile that reconnects gets a new one.
    var connectionIDs: Set<Int> { link.connectionIDs }

    /// Stands for the owner of windows no connected profile can see, such as those of a profile without the extension.
    static let nobody = 0

    /// Which connected profile can see each of `windowIDs`, by connection. A profile's extension sees only its own
    /// profile's windows, so each window has one owner, or `nobody`. A window some profile did not answer about is
    /// left out, since it may be that profile's.
    func owners(of windowIDs: [Int], timeout: TimeInterval = 2, completion: @escaping ([Int: Int]) -> Void) {
        queue.async { [self] in
            let finish = { (owners: [Int: Int]) in DispatchQueue.main.async { completion(owners) } }
            let asked = link.connected
            guard link.startError == nil, !asked.isEmpty, !windowIDs.isEmpty else { return finish([:]) }
            var owners: [Int: Int] = [:]
            var unanswered: Set<Int> = []
            var remaining = windowIDs.count * asked.count
            for window in windowIDs {
                for connection in asked {
                    request(["type": "tabs", "windowId": window], on: connection, timeout: timeout) { result in
                        switch result {
                        case .success(let reply) where reply["tabs"] != nil: owners[window] = connection
                        case .success(let reply) where reply["error"] as? String == "no-window": break
                        default: unanswered.insert(window)
                        }
                        remaining -= 1
                        guard remaining == 0 else { return }
                        for window in windowIDs where owners[window] == nil && !unanswered.contains(window) {
                            owners[window] = Self.nobody
                        }
                        finish(owners)
                    }
                }
            }
        }
    }

    func stop() { link.stop() }

    /// Asks every connected profile for the window's tabs; the one whose profile has the window answers.
    func tabs(inWindow windowID: Int, timeout: TimeInterval = 3, completion: @escaping (Result<Window, Error>) -> Void) {
        queue.async { [self] in
            let finish = { (result: Result<Window, Error>) in DispatchQueue.main.async { completion(result) } }
            if let reason = link.startError { return finish(.failure(LinkError.unavailable(reason))) }
            let asked = link.connected
            guard !asked.isEmpty else { return finish(.failure(LinkError.notConnected)) }
            var remaining = asked.count
            var answered = false
            var failure: Error = LinkError.windowNotFound
            for connection in asked {
                request(["type": "tabs", "windowId": windowID], on: connection, timeout: timeout) { result in
                    remaining -= 1
                    guard !answered else { return }
                    switch result {
                    case .success(let reply):
                        if let tabs = reply["tabs"] as? [[String: Any]] {
                            answered = true
                            return finish(.success(Window(id: windowID, tabs: tabs.compactMap(GroupableTab.init(json:)), connection: connection)))
                        }
                        // Other profiles cannot see the window; anything else is worth reporting.
                        if let error = reply["error"] as? String, error != "no-window" { failure = LinkError.refused(error) }
                    case .failure(let error):
                        if failure as? LinkError == .windowNotFound { failure = error }
                    }
                    if remaining == 0 { finish(.failure(failure)) }
                }
            }
        }
    }

    /// Has the extension of the profile that has the window do `type`, such as "mute", and answers its reply.
    /// Every connected profile is asked; the others cannot see the window and say so.
    func perform(_ type: String, inWindow windowID: Int, timeout: TimeInterval = 5,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            let finish = { (result: Result<[String: Any], Error>) in DispatchQueue.main.async { completion(result) } }
            if let reason = link.startError { return finish(.failure(LinkError.unavailable(reason))) }
            let asked = link.connected
            guard !asked.isEmpty else { return finish(.failure(LinkError.notConnected)) }
            var remaining = asked.count
            var answered = false
            var failure: Error = LinkError.windowNotFound
            for connection in asked {
                request(["type": type, "windowId": windowID], on: connection, timeout: timeout) { result in
                    remaining -= 1
                    guard !answered else { return }
                    switch result {
                    case .success(let reply):
                        guard let error = reply["error"] as? String else {
                            answered = true
                            return finish(.success(reply))
                        }
                        // An extension from before the request existed does not know it, whichever window is meant.
                        if error == "unknown request" { failure = LinkError.outdated }
                        else if error != "no-window", failure as? LinkError != .outdated { failure = LinkError.refused(error) }
                    case .failure(let error):
                        if failure as? LinkError == .windowNotFound { failure = error }
                    }
                    if remaining == 0 { finish(.failure(failure)) }
                }
            }
        }
    }

    /// Has the extension that listed `window` make the groups; answers how many it made.
    func group(_ groups: [PlannedGroup], in window: Window, timeout: TimeInterval = 10,
               completion: @escaping (Result<Int, Error>) -> Void) {
        let message: [String: Any] = ["type": "group", "windowId": window.id,
                                      "groups": groups.map { ["title": $0.title, "tabIds": $0.tabIDs] }]
        queue.async { [self] in
            request(message, on: window.connection, timeout: timeout) { result in
                let made = result.flatMap { reply -> Result<Int, Error> in
                    if let made = reply["grouped"] as? Int { return .success(made) }
                    return .failure(LinkError.refused(reply["error"] as? String ?? "no answer"))
                }
                DispatchQueue.main.async { completion(made) }
            }
        }
    }

    // MARK: - On `queue`

    private func request(_ message: [String: Any], on connection: Int, timeout: TimeInterval,
                         completion: @escaping (Result<[String: Any], Error>) -> Void) {
        link.request(message, on: connection, timeout: timeout) { result in
            completion(result.mapError { error -> Error in
                switch error as? ExtensionLink.Failure {
                case .timeout?: return LinkError.timeout
                case .unavailable(let reason)?: return LinkError.unavailable(reason)
                default: return LinkError.notConnected
                }
            })
        }
    }
}

extension GroupableTab {
    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", url: json["url"] as? String ?? "",
                  pinned: json["pinned"] as? Bool ?? false, grouped: json["grouped"] as? Bool ?? false)
    }
}

/// Lets Chrome start TabScoutChromeHost for Tab Scout's extension, in every Chrome profile.
enum ChromeHostManifest {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Google/Chrome/NativeMessagingHosts/\(NativeMessage.hostName).json")
    }

    static func contents(helper: URL) -> Data {
        let manifest: [String: Any] = [
            "name": NativeMessage.hostName,
            "description": "Tab Scout",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(NativeMessage.extensionID)/"]
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func install(helper: URL, at url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents(helper: helper).write(to: url, options: .atomic)
    }
}

import Darwin
import Foundation
import os

/// Tab Scout's extension in each Chrome profile that has it. Chrome makes tab groups only for extensions, so the
/// app asks the extension for a window's tabs and has it group them. Chrome starts TabScoutChromeHost for the
/// extension; the helper connects to this socket and passes messages on. Only that helper may connect.
final class ChromeExtensionLink {
    enum LinkError: LocalizedError, Equatable {
        case unavailable(String)
        case notConnected
        case windowNotFound
        case refused(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Tab Scout cannot reach its Chrome extension: \(reason)"
            case .notConnected: return "Add Tab Scout's extension to Chrome to group tabs."
            case .windowNotFound: return "This Chrome profile does not have Tab Scout's extension."
            case .refused(let reason): return "Chrome could not group the tabs: \(reason)"
            case .timeout: return "Tab Scout's Chrome extension did not answer. Try again."
            }
        }
    }

    /// One Chrome window's tabs, from the extension of the profile the window belongs to.
    struct Window {
        let id: Int
        let tabs: [GroupableTab]
        fileprivate let connection: Int
    }

    private final class Connection {
        let descriptor: Int32
        let source: DispatchSourceRead
        var buffer = Data()

        init(descriptor: Int32, source: DispatchSourceRead) {
            self.descriptor = descriptor
            self.source = source
        }
    }

    private static let logger = Logger(subsystem: "local.tabscout.app", category: "chrome")
    private let socketURL: URL
    private let verifyPeer: (Int32) -> Bool
    private let queue = DispatchQueue(label: "local.tabscout.chrome-link")
    // Owned by `queue`.
    private var listener: DispatchSourceRead?
    private var startError: String?
    private var connections: [Int: Connection] = [:]
    private var replies: [Int: (connection: Int, handler: (Result<[String: Any], Error>) -> Void)] = [:]
    private var nextConnection = 1
    private var nextRequest = 1

    /// `verifyPeer` decides whether a connecting process may talk to the extension; by default it must be the
    /// helper in this app's bundle.
    init(socketURL: URL = NativeMessage.socketURL, verifyPeer: ((Int32) -> Bool)? = nil) {
        self.socketURL = socketURL
        let helper = Bundle.main.url(forAuxiliaryExecutable: "TabScoutChromeHost")
        self.verifyPeer = verifyPeer ?? { socket in helper.map { CodeIdentity.peer(of: socket, isSignedLike: $0) } ?? false }
    }

    /// Listens for helpers. A failure is reported by the next request instead.
    func start() {
        queue.sync {
            guard listener == nil else { return }
            do { try listen() } catch {
                startError = error.localizedDescription
                Self.logger.error("Not listening for the Chrome extension: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for id in Array(connections.keys) { disconnect(id) }
            unlink(socketURL.path)
        }
    }

    /// Asks every connected profile for the window's tabs; the one whose profile has the window answers.
    func tabs(inWindow windowID: Int, timeout: TimeInterval = 3, completion: @escaping (Result<Window, Error>) -> Void) {
        queue.async { [self] in
            let finish = { (result: Result<Window, Error>) in DispatchQueue.main.async { completion(result) } }
            if let startError { return finish(.failure(LinkError.unavailable(startError))) }
            guard !connections.isEmpty else { return finish(.failure(LinkError.notConnected)) }
            var remaining = connections.count
            var answered = false
            var failure: Error = LinkError.windowNotFound
            for connection in connections.keys {
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

    private func listen() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard var address = NativeMessage.address(socketURL) else { throw LinkError.unavailable("the socket path is too long") }
        // Left behind by a Tab Scout that quit without cleaning up; only one copy of the app runs.
        unlink(socketURL.path)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketURL.path, 0o600) == 0, Darwin.listen(socket, 8) == 0,
              fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socket)
            throw POSIXError(code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: socket) }
        source.setCancelHandler { close(socket) }
        listener = source
        source.resume()
    }

    private func accept(on socket: Int32) {
        while true {
            let client = Darwin.accept(socket, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit the listener's non-blocking mode, which would cut writes short.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            // The greeting tells the helper it was let in; one turned away quits so Chrome can start a current one.
            guard verifyPeer(client), NativeMessage.write(NativeMessage.frame(Data(#"{"type":"hello"}"#.utf8)), to: client) else {
                Self.logger.notice("Turned away a connection that is not Tab Scout's Chrome helper")
                close(client)
                continue
            }
            NativeMessage.noSignalOnClose(client)
            let id = nextConnection
            nextConnection += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.receive(on: id) }
            source.setCancelHandler { close(client) }
            connections[id] = Connection(descriptor: client, source: source)
            source.resume()
            Self.logger.notice("Chrome extension \(id, privacy: .public) connected")
        }
    }

    private func receive(on id: Int) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(connection.descriptor, &chunk, chunk.count)
        guard count > 0 else { return disconnect(id) }
        connection.buffer.append(contentsOf: chunk[0..<count])
        guard let messages = NativeMessage.messages(from: &connection.buffer) else { return disconnect(id) }
        for data in messages {
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let reply = message["id"] as? Int, replies[reply]?.connection == id,
                  let waiting = replies.removeValue(forKey: reply) else { continue }
            waiting.handler(.success(message))
        }
    }

    private func disconnect(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        Self.logger.notice("Chrome extension \(id, privacy: .public) disconnected")
        for (reply, waiting) in replies where waiting.connection == id {
            replies[reply] = nil
            waiting.handler(.failure(LinkError.notConnected))
        }
    }

    private func request(_ message: [String: Any], on connection: Int, timeout: TimeInterval,
                         completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextRequest
        nextRequest += 1
        var message = message
        message["id"] = id
        guard let target = connections[connection], let data = try? JSONSerialization.data(withJSONObject: message),
              NativeMessage.write(NativeMessage.frame(data), to: target.descriptor) else {
            return completion(.failure(LinkError.notConnected))
        }
        replies[id] = (connection, completion)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.replies.removeValue(forKey: id)?.handler(.failure(LinkError.timeout))
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

import Darwin
import Foundation
import os

/// The app's end of the socket a browser's copies of Tab Scout's extension reach it through. The browser starts a
/// helper from Tab Scout.app for each copy; the helper connects here and passes messages on. Only that helper may
/// connect. Requests are numbered, and the reply carrying a request's number answers it.
final class ExtensionLink {
    enum Failure: Error, Equatable {
        case unavailable(String)
        case notConnected
        case timeout
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

    /// Requests are made, and everything is called back, on this queue.
    let queue: DispatchQueue
    private let logger: Logger
    private let name: String
    private let socketURL: URL
    private let verifyPeer: (Int32) -> Bool
    // Owned by `queue`.
    private var listener: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var replies: [Int: (connection: Int, handler: (Result<[String: Any], Error>) -> Void)] = [:]
    private var nextConnection = 1
    private var nextRequest = 1
    /// Why the socket could not be opened, which each request then reports.
    private(set) var startError: String?
    /// Decides whether a helper that passed `verifyPeer` is let in, given its number and its socket.
    var onConnect: ((Int, Int32) -> Bool)?
    var onDisconnect: ((Int) -> Void)?
    /// A message that answers no request, such as an extension saying what changed.
    var onMessage: ((Int, [String: Any]) -> Void)?

    /// `name` is the browser in the log, such as "Chrome". `verifyPeer` decides whether a connecting process is
    /// Tab Scout's helper.
    init(name: String, socketURL: URL, verifyPeer: @escaping (Int32) -> Bool) {
        self.name = name
        self.socketURL = socketURL
        self.verifyPeer = verifyPeer
        queue = DispatchQueue(label: "local.tabscout.\(name.lowercased())-link")
        logger = Logger(subsystem: "local.tabscout.app", category: name.lowercased())
    }

    /// Listens for helpers. A failure is reported by the next request instead.
    func start() {
        queue.sync {
            guard listener == nil else { return }
            do { try listen() } catch {
                startError = error.localizedDescription
                logger.error("Not listening for the \(self.name, privacy: .public) extension: \(error.localizedDescription, privacy: .public)")
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

    /// The connected extensions, by number; one that reconnects gets a new one. Not for use on `queue`.
    var connectionIDs: Set<Int> { queue.sync { Set(connections.keys) } }

    // MARK: - On `queue`

    var connected: [Int] { Array(connections.keys) }

    /// Sends `message` to one extension and answers its reply, a failure when it has gone, or a timeout.
    func request(_ message: [String: Any], on connection: Int, timeout: TimeInterval,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextRequest
        nextRequest += 1
        var message = message
        message["id"] = id
        guard let target = connections[connection], let data = try? JSONSerialization.data(withJSONObject: message),
              NativeMessage.write(NativeMessage.frame(data), to: target.descriptor) else {
            return completion(.failure(Failure.notConnected))
        }
        replies[id] = (connection, completion)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.replies.removeValue(forKey: id)?.handler(.failure(Failure.timeout))
        }
    }

    private func listen() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard var address = NativeMessage.address(socketURL) else { throw Failure.unavailable("the socket path is too long") }
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
            let id = nextConnection
            // The greeting tells the helper it was let in; one turned away quits so the browser can start a current one.
            guard verifyPeer(client), onConnect?(id, client) ?? true,
                  NativeMessage.write(NativeMessage.frame(Data(#"{"type":"hello"}"#.utf8)), to: client) else {
                logger.notice("Turned away a connection that is not Tab Scout's \(self.name, privacy: .public) helper")
                close(client)
                continue
            }
            NativeMessage.noSignalOnClose(client)
            nextConnection += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.receive(on: id) }
            source.setCancelHandler { close(client) }
            connections[id] = Connection(descriptor: client, source: source)
            source.resume()
            logger.notice("\(self.name, privacy: .public) extension \(id, privacy: .public) connected")
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
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let reply = message["id"] as? Int {
                guard replies[reply]?.connection == id, let waiting = replies.removeValue(forKey: reply) else { continue }
                waiting.handler(.success(message))
            } else {
                onMessage?(id, message)
            }
        }
    }

    private func disconnect(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        logger.notice("\(self.name, privacy: .public) extension \(id, privacy: .public) disconnected")
        for (reply, waiting) in replies where waiting.connection == id {
            replies[reply] = nil
            waiting.handler(.failure(Failure.notConnected))
        }
        onDisconnect?(id)
    }
}

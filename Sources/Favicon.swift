import AppKit
import CryptoKit
import Foundation
import ImageIO

struct FaviconOrigin: Hashable {
    let url: URL
    var key: String { url.absoluteString }
    var cacheKey: String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    init?(_ address: String) {
        guard let input = URLComponents(string: address),
              let scheme = input.scheme?.lowercased(), ["http", "https"].contains(scheme),
              input.user == nil, input.password == nil,
              var host = input.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard Self.publicHost(host) else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = (scheme == "https" && input.port == 443) || (scheme == "http" && input.port == 80) ? nil : input.port
        guard origin.port == nil || (1...65535).contains(origin.port!), let url = origin.url else { return nil }
        self.url = url
    }

    func accepts(_ candidate: URL) -> Bool { FaviconOrigin(candidate.absoluteString) == self }

    private static func publicHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.contains(":"), host.contains("."),
              !["localhost", "local", "internal", "lan", "home", "test", "invalid"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = pieces.allSatisfy { piece in
            piece.allSatisfy(\.isNumber) || (piece.hasPrefix("0x") && !piece.dropFirst(2).isEmpty && piece.dropFirst(2).allSatisfy(\.isHexDigit))
        }
        if numeric {
            guard pieces.count == 4 else { return false }
            guard pieces.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else { return false }
            let bytes = pieces.compactMap { UInt8($0) }
            guard bytes.count == 4 else { return false }
            let a = bytes[0], b = bytes[1]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                     (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                     (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) ||
                     (a == 198 && (b == 18 || b == 19)))
        }
        return true
    }
}

struct FaviconResponse {
    let data: Data
    let url: URL
    let statusCode: Int
    let mimeType: String?
}

protocol FaviconTransport {
    func fetch(_ url: URL, completion: @escaping (Result<FaviconResponse, Error>) -> Void)
}

private enum FaviconFailure: Error { case unsafeURL, response, oversized }

final class FaviconURLTransport: NSObject, FaviconTransport, URLSessionDataDelegate {
    static let maximumBytes = 1_048_576
    private struct Transfer {
        let origin: FaviconOrigin
        let completion: (Result<FaviconResponse, Error>) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var redirects = 0
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!

    init(configuration supplied: URLSessionConfiguration? = nil) {
        super.init()
        let configuration = supplied?.copy() as? URLSessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 4
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func fetch(_ url: URL, completion: @escaping (Result<FaviconResponse, Error>) -> Void) {
        guard let origin = FaviconOrigin(url.absoluteString) else { completion(.failure(FaviconFailure.unsafeURL)); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("TabScout/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*,text/html;q=0.8,application/xhtml+xml;q=0.8", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(origin: origin, completion: completion)
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier], let response = response as? HTTPURLResponse,
              let url = response.url, transfer.origin.accepts(url), (200..<300).contains(response.statusCode) else {
            lock.unlock(); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Self.maximumBytes else {
            transfer.error = FaviconFailure.oversized
            transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); completionHandler(.cancel); return
        }
        transfer.response = response
        transfers[dataTask.taskIdentifier] = transfer
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier] else { lock.unlock(); return }
        if transfer.data.count + data.count > Self.maximumBytes {
            transfer.error = FaviconFailure.oversized
            transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); dataTask.cancel(); return
        }
        transfer.data.append(data)
        transfers[dataTask.taskIdentifier] = transfer
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        guard var transfer = transfers[task.taskIdentifier], let url = request.url,
              transfer.origin.accepts(url), transfer.redirects < 3 else {
            lock.unlock(); completionHandler(nil); return
        }
        transfer.redirects += 1
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
        var request = request
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let transfer else { return }
        if let error = transfer.error ?? error { transfer.completion(.failure(error)); return }
        guard let response = transfer.response, let url = response.url else { transfer.completion(.failure(FaviconFailure.response)); return }
        transfer.completion(.success(FaviconResponse(data: transfer.data, url: url, statusCode: response.statusCode, mimeType: response.mimeType)))
    }
}

enum FaviconHTML {
    static func candidates(in data: Data, origin: FaviconOrigin) -> [URL] {
        guard data.count <= FaviconURLTransport.maximumBytes,
              let document = try? XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let links = try? document.nodes(forXPath: "//*[local-name()='link']") else { return [] }
        var candidates: [(Int, Int, URL)] = []
        for (offset, node) in links.prefix(128).enumerated() {
            guard let link = node as? XMLElement,
                  let rel = link.attribute(forName: "rel")?.stringValue?.lowercased(),
                  let href = link.attribute(forName: "href")?.stringValue,
                  let candidate = URL(string: href, relativeTo: origin.url.appendingPathComponent("/"))?.absoluteURL,
                  origin.accepts(candidate) else { continue }
            let tokens = rel.split(whereSeparator: \.isWhitespace)
            guard tokens.contains("icon") || tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed") else { continue }
            var parts = URLComponents(url: candidate, resolvingAgainstBaseURL: true)
            parts?.fragment = nil
            guard let url = parts?.url else { continue }
            let rank = tokens.contains("icon") ? 0 : 1
            candidates.append((rank, offset, url))
        }
        var seen = Set<URL>()
        return candidates.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.compactMap {
            seen.insert($0.2).inserted ? $0.2 : nil
        }.prefix(4).map { $0 }
    }
}

final class FaviconStore {
    struct Configuration {
        var maximumEntries = 256
        var maximumConcurrentOrigins = 4
        var positiveTTL: TimeInterval = 7 * 24 * 60 * 60
        var negativeTTL: TimeInterval = 60 * 60
    }
    private struct DiskEntry: Codable {
        let expires: Date
        var accessed: Date
        let png: Data?
    }
    private struct Entry {
        var disk: DiskEntry
        let image: NSImage?
    }
    private let transport: FaviconTransport
    private let directory: URL
    private let clock: () -> Date
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "local.tabscout.favicons", qos: .utility)
    private let memoryLock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pending: [FaviconOrigin: [(NSImage?) -> Void]] = [:]
    private var waiting: [FaviconOrigin] = []
    private var active = 0

    init(transport: FaviconTransport = FaviconURLTransport(), directory: URL? = nil,
         clock: @escaping () -> Date = Date.init, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.tabscout.app/Favicons-v1", isDirectory: true)
        self.clock = clock
        self.configuration = configuration
        queue.async { self.loadDisk() }
    }

    func imageFor(url: String) -> NSImage? {
        guard let origin = FaviconOrigin(url) else { return nil }
        memoryLock.lock()
        defer { memoryLock.unlock() }
        let key = origin.cacheKey
        guard var entry = entries[key], entry.disk.expires > clock() else { return nil }
        entry.disk.accessed = clock()
        entries[key] = entry
        return entry.image
    }

    func request(url: String, completion: @escaping (NSImage?) -> Void) {
        guard let origin = FaviconOrigin(url) else { deliver([completion], image: nil); return }
        queue.async {
            let key = origin.cacheKey
            self.memoryLock.lock()
            var entry = self.entries[key]
            if entry?.disk.expires ?? .distantPast <= self.clock() { entry = nil }
            if var cached = entry {
                cached.disk.accessed = self.clock()
                self.entries[key] = cached
                self.memoryLock.unlock()
                self.write(cached.disk, key: key)
                self.deliver([completion], image: cached.image)
                return
            }
            self.memoryLock.unlock()
            if self.pending[origin] != nil {
                if self.pending[origin]!.count < 64 { self.pending[origin]!.append(completion) }
                else { self.deliver([completion], image: nil) }
                return
            }
            guard self.pending.count < self.configuration.maximumEntries else { self.deliver([completion], image: nil); return }
            self.pending[origin] = [completion]
            self.waiting.append(origin)
            self.pump()
        }
    }

    private func pump() {
        while active < max(1, configuration.maximumConcurrentOrigins), !waiting.isEmpty {
            let origin = waiting.removeFirst()
            active += 1
            transport.fetch(origin.url.appendingPathComponent("/")) { result in
                self.queue.async {
                    var candidates: [URL] = []
                    if case .success(let response) = result, self.accept(response, origin: origin),
                       ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") {
                        candidates = FaviconHTML.candidates(in: response.data, origin: origin)
                    }
                    let fallback = origin.url.appendingPathComponent("favicon.ico")
                    if !candidates.contains(fallback) { candidates.append(fallback) }
                    self.fetchIcon(candidates, origin: origin)
                }
            }
        }
    }

    private func fetchIcon(_ candidates: [URL], origin: FaviconOrigin) {
        guard let candidate = candidates.first else { finish(origin, png: nil, image: nil); return }
        transport.fetch(candidate) { result in
            self.queue.async {
                if case .success(let response) = result, self.accept(response, origin: origin),
                   let decoded = Self.decode(response.data) {
                    self.finish(origin, png: decoded.0, image: decoded.1)
                } else { self.fetchIcon(Array(candidates.dropFirst()), origin: origin) }
            }
        }
    }

    private func accept(_ response: FaviconResponse, origin: FaviconOrigin) -> Bool {
        origin.accepts(response.url) && (200..<300).contains(response.statusCode) && response.data.count <= FaviconURLTransport.maximumBytes
    }

    private func finish(_ origin: FaviconOrigin, png: Data?, image: NSImage?) {
        let now = clock()
        let disk = DiskEntry(expires: now.addingTimeInterval(png == nil ? configuration.negativeTTL : configuration.positiveTTL), accessed: now, png: png)
        memoryLock.lock()
        entries[origin.cacheKey] = Entry(disk: disk, image: image)
        let obsolete = entries.sorted { $0.value.disk.accessed > $1.value.disk.accessed }.dropFirst(max(1, configuration.maximumEntries)).map(\.key)
        for key in obsolete { entries.removeValue(forKey: key) }
        memoryLock.unlock()
        for key in obsolete { try? FileManager.default.removeItem(at: file(key)) }
        write(disk, key: origin.cacheKey)
        let callbacks = pending.removeValue(forKey: origin) ?? []
        active -= 1
        deliver(callbacks, image: image)
        pump()
    }

    private func deliver(_ callbacks: [(NSImage?) -> Void], image: NSImage?) {
        DispatchQueue.main.async { for callback in callbacks { callback(image) } }
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func write(_ disk: DiskEntry, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    private func loadDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var restored: [(String, Entry)] = []
        for file in files where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent.count == 64 {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? Int.max) <= 32_768,
                  let data = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(DiskEntry.self, from: data),
                  disk.expires > clock(), disk.png == nil || Self.decode(disk.png!) != nil else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let image = disk.png.flatMap { Self.decode($0)?.1 }
            restored.append((file.deletingPathExtension().lastPathComponent, Entry(disk: disk, image: image)))
        }
        restored.sort { $0.1.disk.accessed > $1.1.disk.accessed }
        memoryLock.lock()
        for (key, entry) in restored.prefix(max(1, configuration.maximumEntries)) { entries[key] = entry }
        memoryLock.unlock()
        for (key, _) in restored.dropFirst(max(1, configuration.maximumEntries)) { try? FileManager.default.removeItem(at: file(key)) }
    }

    private static func decode(_ data: Data) -> (Data, NSImage)? {
        guard !data.isEmpty, data.count <= FaviconURLTransport.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetCount(source) <= 64,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) else { return nil }
        return (png, NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
    }
}

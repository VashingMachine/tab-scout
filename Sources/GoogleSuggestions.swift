import Foundation

struct GoogleSuggestionResult {
    let query: String
    let suggestions: [String]
}

enum GoogleSuggestionQuery {
    static let maximumCharacters = 120

    static func eligible(_ input: String) -> String? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...maximumCharacters).contains(query.count),
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let lower = query.lowercased()
        if let colon = lower.firstIndex(of: ":"), !lower[..<colon].contains(where: \.isWhitespace) {
            let prefix = lower[..<colon]
            if prefix.first?.isLetter == true && prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                return nil
            }
        }
        guard !lower.contains("://"), !lower.contains("@"), !lower.contains("/"), !lower.contains("\\"),
              !lower.hasPrefix("~"), !lower.hasPrefix("http:"), !lower.hasPrefix("https:"),
              !["bearer ", "authorization", "password", "passwd", "token", "api key", "api_key", "apikey",
                "access_token", "refresh_token", "client_secret", "secret", "sk-", "ghp_", "github_pat_",
                "glpat-", "akia"].contains(where: { lower.hasPrefix($0) }) else { return nil }
        for token in lower.split(whereSeparator: \.isWhitespace) {
            let token = String(token)
            if token == "localhost" || token.hasPrefix("localhost:") || token.hasPrefix("www.") { return nil }
            let host = token.split(separator: ":", maxSplits: 1).first.map(String.init) ?? token
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) }) {
                if let suffix = parts.last, suffix.count >= 2 && suffix.allSatisfy(\.isLetter) { return nil }
                if parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) { return nil }
            }
            if token.hasPrefix("[") && token.contains(":") { return nil }
        }
        return query
    }
}

enum GoogleSuggestionFailure: Error { case unsafeQuery, response, oversized, malformed }

struct GoogleSuggestionResponse {
    let data: Data
    let url: URL
    let statusCode: Int
    let mimeType: String?
}

protocol GoogleSuggestionCancellation {
    func cancel()
}

extension URLSessionTask: GoogleSuggestionCancellation {}
extension DispatchWorkItem: GoogleSuggestionCancellation {}

protocol GoogleSuggestionTransport {
    func fetch(query: String, completion: @escaping (Result<GoogleSuggestionResponse, Error>) -> Void) -> GoogleSuggestionCancellation
}

enum GoogleSuggestionDecoder {
    static let maximumBytes = 65_536
    static let maximumSuggestions = 8

    static func decode(_ response: GoogleSuggestionResponse, query: String) throws -> [String] {
        guard response.data.count <= maximumBytes else { throw GoogleSuggestionFailure.oversized }
        guard response.statusCode == 200,
              GoogleSuggestionsURLTransport.accepts(response.url, query: query),
              ["application/json", "text/javascript", "application/javascript"].contains(response.mimeType?.lowercased() ?? "") else {
            throw GoogleSuggestionFailure.response
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [Any], root.count >= 2,
              let echoedQuery = root[0] as? String, echoedQuery == query,
              let candidates = root[1] as? [Any] else { throw GoogleSuggestionFailure.malformed }
        var seen = Set<String>()
        var suggestions: [String] = []
        for candidate in candidates.prefix(64) {
            let text = (candidate as? String) ?? (candidate as? [Any])?.first as? String
            guard let text else { continue }
            let textValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textValue.isEmpty, textValue.count <= GoogleSuggestionQuery.maximumCharacters,
                  textValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(textValue.lowercased()).inserted else { continue }
            suggestions.append(textValue)
            if suggestions.count == maximumSuggestions { break }
        }
        return suggestions
    }
}

// Google's Safari-compatible autocomplete endpoint is undocumented and best effort.
// Only opted-in search text is sent: no cookies, credentials, referrer, tabs, or history.
final class GoogleSuggestionsURLTransport: NSObject, GoogleSuggestionTransport, URLSessionDataDelegate {
    private struct Transfer {
        let query: String
        let completion: (Result<GoogleSuggestionResponse, Error>) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
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
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func request(query: String) -> URLRequest? {
        guard GoogleSuggestionQuery.eligible(query) == query else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "suggestqueries.google.com"
        components.path = "/complete/search"
        components.queryItems = [URLQueryItem(name: "client", value: "safari"), URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func accepts(_ url: URL, query: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "suggestqueries.google.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/complete/search", let items = components.queryItems, items.count == 2 else { return false }
        return items.filter({ $0.name == "client" && $0.value == "safari" }).count == 1 &&
               items.filter({ $0.name == "q" && $0.value == query }).count == 1
    }

    func fetch(query: String, completion: @escaping (Result<GoogleSuggestionResponse, Error>) -> Void) -> GoogleSuggestionCancellation {
        guard let request = Self.request(query: query) else {
            completion(.failure(GoogleSuggestionFailure.unsafeQuery))
            return DispatchWorkItem {}
        }
        let task = session.dataTask(with: request)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(query: query, completion: completion)
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, let url = response.url,
              Self.accepts(url, query: transfer.query), response.statusCode == 200 else {
            transfer.error = GoogleSuggestionFailure.response
            transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= GoogleSuggestionDecoder.maximumBytes else {
            transfer.error = GoogleSuggestionFailure.oversized
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
        guard transfer.data.count + data.count <= GoogleSuggestionDecoder.maximumBytes else {
            transfer.error = GoogleSuggestionFailure.oversized
            transfers[dataTask.taskIdentifier] = transfer
            lock.unlock(); dataTask.cancel(); return
        }
        transfer.data.append(data)
        transfers[dataTask.taskIdentifier] = transfer
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
        guard let response = transfer.response, let url = response.url else {
            transfer.completion(.failure(GoogleSuggestionFailure.response)); return
        }
        transfer.completion(.success(GoogleSuggestionResponse(data: transfer.data, url: url, statusCode: response.statusCode, mimeType: response.mimeType)))
    }
}

// Main-thread owned. Search results never wait for remote suggestions.
final class GoogleSuggestionsService {
    struct Configuration {
        var debounce: TimeInterval = 0.18
        var cacheTTL: TimeInterval = 300
        var maximumCacheEntries = 64
    }
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> GoogleSuggestionCancellation
    private struct CacheEntry {
        let suggestions: [String]
        let storedAt: Date
        var lastAccess: UInt64
    }
    private struct Pending {
        let query: String
        let generation: UInt64
        var callbacks: [(GoogleSuggestionResult) -> Void]
        var schedule: GoogleSuggestionCancellation?
        var transfer: GoogleSuggestionCancellation?
    }
    private let transport: GoogleSuggestionTransport
    private let now: () -> Date
    private let scheduler: Scheduler
    private let configuration: Configuration
    private var cache: [String: CacheEntry] = [:]
    private var pending: Pending?
    private var generation: UInt64 = 0
    private var access: UInt64 = 0

    init(transport: GoogleSuggestionTransport = GoogleSuggestionsURLTransport(), now: @escaping () -> Date = Date.init,
         configuration: Configuration = Configuration(), scheduler: @escaping Scheduler = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return item
         }) {
        self.transport = transport
        self.now = now
        self.scheduler = scheduler
        var configuration = configuration
        configuration.debounce = configuration.debounce.isFinite ? max(0, configuration.debounce) : 0.18
        configuration.cacheTTL = configuration.cacheTTL.isFinite ? max(0, configuration.cacheTTL) : 300
        configuration.maximumCacheEntries = max(1, min(256, configuration.maximumCacheEntries))
        self.configuration = configuration
    }

    func suggestions(for input: String, completion: @escaping (GoogleSuggestionResult) -> Void) {
        precondition(Thread.isMainThread)
        guard let query = GoogleSuggestionQuery.eligible(input) else {
            cancel()
            completion(GoogleSuggestionResult(query: input.trimmingCharacters(in: .whitespacesAndNewlines), suggestions: []))
            return
        }
        if pending?.query == query {
            pending?.callbacks.append(completion)
            return
        }
        cancel()
        purgeExpiredEntries()
        if var entry = cache[query] {
            access &+= 1
            entry.lastAccess = access
            cache[query] = entry
            completion(GoogleSuggestionResult(query: query, suggestions: entry.suggestions))
            return
        }
        let ticket = generation
        pending = Pending(query: query, generation: ticket, callbacks: [completion])
        let scheduled = scheduler(configuration.debounce) { [weak self] in
            guard let self, self.pending?.generation == ticket else { return }
            self.pending?.schedule = nil
            let transfer = self.transport.fetch(query: query) { [weak self] response in
                let action: () -> Void = { [weak self] in self?.finish(response, query: query, generation: ticket) }
                if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
            }
            if self.pending?.generation == ticket { self.pending?.transfer = transfer } else { transfer.cancel() }
        }
        if pending?.generation == ticket { pending?.schedule = scheduled } else { scheduled.cancel() }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        pending?.schedule?.cancel()
        pending?.transfer?.cancel()
        pending = nil
    }

    func clearCache() {
        cancel()
        cache.removeAll()
    }

    private func finish(_ result: Result<GoogleSuggestionResponse, Error>, query: String, generation: UInt64) {
        guard let pending, pending.generation == generation, pending.query == query else { return }
        self.pending = nil
        let suggestions: [String]
        do {
            suggestions = try GoogleSuggestionDecoder.decode(result.get(), query: query)
            purgeExpiredEntries()
            access &+= 1
            cache[query] = CacheEntry(suggestions: suggestions, storedAt: now(), lastAccess: access)
            while cache.count > configuration.maximumCacheEntries {
                if let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key { cache.removeValue(forKey: oldest) }
            }
        } catch { suggestions = [] }
        let output = GoogleSuggestionResult(query: query, suggestions: suggestions)
        pending.callbacks.forEach { $0(output) }
    }

    private func purgeExpiredEntries() {
        let date = now()
        cache = cache.filter {
            let age = date.timeIntervalSince($0.value.storedAt)
            return age >= 0 && age < configuration.cacheTTL
        }
    }
}

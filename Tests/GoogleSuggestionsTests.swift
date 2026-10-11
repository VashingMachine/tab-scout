import Foundation

private final class TestCancellation: GoogleSuggestionCancellation {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

private final class TestScheduler {
    struct Job {
        let delay: TimeInterval
        let action: () -> Void
        let cancellation: TestCancellation
    }
    var jobs: [Job] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> GoogleSuggestionCancellation {
        let cancellation = TestCancellation()
        jobs.append(Job(delay: delay, action: action, cancellation: cancellation))
        return cancellation
    }
    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        let job = jobs[index]
        if evenIfCancelled || !job.cancellation.cancelled { job.action() }
    }
}

private final class TestTransport: GoogleSuggestionTransport {
    struct Transfer {
        let query: String
        let callback: (Result<GoogleSuggestionResponse, Error>) -> Void
        let cancellation: TestCancellation
    }
    var transfers: [Transfer] = []
    var immediate: GoogleSuggestionResponse?
    func fetch(query: String, completion: @escaping (Result<GoogleSuggestionResponse, Error>) -> Void) -> GoogleSuggestionCancellation {
        let cancellation = TestCancellation()
        transfers.append(Transfer(query: query, callback: completion, cancellation: cancellation))
        if let immediate { completion(.success(immediate)) }
        return cancellation
    }
    func succeed(_ index: Int, _ values: [String]) {
        transfers[index].callback(.success(GoogleSuggestionsTests.response(transfers[index].query, values)))
    }
}

private final class SuggestionURLProtocol: URLProtocol {
    static var handler: ((SuggestionURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func reply(status: Int = 200, mime: String = "application/json", chunks: [Data], length: Int? = nil) {
        var headers = ["Content-Type": mime]
        if let length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct GoogleSuggestionsTests {
    static var checks = 0

    static func main() {
        queryPolicy()
        requestPolicy()
        decoding()
        debounceAndCoalescing()
        cancellationAndFailure()
        cachePolicy()
        transportPolicy()
        print("Passed \(checks) Google suggestions checks")
    }

    static func queryPolicy() {
        for input in ["", " ", "a", String(repeating: "x", count: 121), "https://example.com", "HTTP://example.com/private",
                      "www.example.com", "example.com", "example.local", "example.com:8080", "find example.com docs", "127.0.0.1",
                      "localhost", "localhost:3000", "[::1]", "/Users/alice/private", "~/private", "C:\\private", "foo/bar",
                      "alice@example.com", "bearer value", "Authorization: Basic value", "password=hidden", "token=hidden",
                      "api key value", "api_key=value", "apikey value", "access_token=value", "refresh_token=value",
                      "client_secret=value", "secret value", "sk-example", "ghp_example", "github_pat_example", "glpat-example",
                      "file:private", "tel:123456", "chrome:flags", "custom+scheme:value",
                      "AKIAEXAMPLE", "weather\nsecret", "weather\tsecret", "weather\u{0000}secret"] {
            expect(GoogleSuggestionQuery.eligible(input) == nil, "Unsafe or incomplete query stays local: \(input.debugDescription)")
        }
        for input in ["weather", "google calendar", "zażółć", "天气预报", "swift macos app", "pi 3.14", String(repeating: "x", count: 120)] {
            expect(GoogleSuggestionQuery.eligible(input) == input, "Ordinary search text is eligible: \(input)")
        }
        expect(GoogleSuggestionQuery.eligible("  weather  ") == "weather", "Query normalization trims surrounding whitespace")
        expect(GoogleSuggestionQuery.eligible("weather\rhidden") == nil, "Control characters cannot leak into requests")
    }

    static func requestPolicy() {
        let request = GoogleSuggestionsURLTransport.request(query: "zażółć + weather & maps")!
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        expect(components.scheme == "https" && components.host == "suggestqueries.google.com", "Only the fixed HTTPS Google origin is used")
        expect(components.path == "/complete/search", "Only the search-completion endpoint is used")
        expect(components.queryItems == [URLQueryItem(name: "client", value: "safari"), URLQueryItem(name: "q", value: "zażółć + weather & maps")], "Query is encoded structurally without parameter injection")
        expect(request.timeoutInterval == 3 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Request latency is bounded and external URL cache disabled")
        expect(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil, "Request contains no browser cookies")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Referer") == nil, "Request contains no credentials or referrer")
        expect(request.httpBody == nil && request.httpMethod == "GET", "Only public completion GET requests are constructed")
        expect(GoogleSuggestionsURLTransport.request(query: "https://private.example.com") == nil, "Transport repeats query safety validation")
        expect(GoogleSuggestionsURLTransport.request(query: " weather ") == nil, "Transport requires pre-normalized query")
        let base = "https://suggestqueries.google.com/complete/search?client=safari&q=weather"
        expect(GoogleSuggestionsURLTransport.accepts(URL(string: base)!, query: "weather"), "Canonical endpoint is accepted")
        expect(GoogleSuggestionsURLTransport.accepts(URL(string: base.replacingOccurrences(of: ".com/", with: ".com:443/"))!, query: "weather"), "Explicit HTTPS default port is accepted")
        for address in [base.replacingOccurrences(of: "https:", with: "http:"), base.replacingOccurrences(of: "google.com", with: "google.com.evil.test"),
                        base.replacingOccurrences(of: "suggestqueries.google.com", with: "user@suggestqueries.google.com"),
                        base.replacingOccurrences(of: ".com/", with: ".com:8443/"), base.replacingOccurrences(of: "/complete/search", with: "/other"),
                        base + "&extra=1", base + "&q=weather", base + "#fragment", base.replacingOccurrences(of: "client=safari", with: "client=chrome") ] {
            expect(!GoogleSuggestionsURLTransport.accepts(URL(string: address)!, query: "weather"), "Unexpected response URL is rejected: \(address)")
        }
        expect(!GoogleSuggestionsURLTransport.accepts(URL(string: base)!, query: "another query"), "URL response belongs to the requested query")
    }

    static func decoding() {
        expect(decode(response("weather", ["weather radar", "weather map"]), "weather") == ["weather radar", "weather map"], "String-array response is decoded")
        let tuples: [Any] = ["weather", [["weather radar", "", [512]], ["weather map", "", [433]]], ["bh": 0]]
        expect(decode(response(root: tuples, query: "weather"), "weather") == ["weather radar", "weather map"], "Safari tuple-format response is decoded")
        let mixed: [Any] = ["weather", [" weather radar ", ["WEATHER RADAR"], ["weather map"], NSNull(), 7, [], [7], "", "\t", "line\nbreak", String(repeating: "x", count: 121)]]
        expect(decode(response(root: mixed, query: "weather"), "weather") == ["weather radar", "weather map"], "Invalid, duplicate and oversized suggestions are filtered")
        expect(decode(response("zażółć", ["zażółć gęślą", "天气预报"]), "zażółć") == ["zażółć gęślą", "天气预报"], "Unicode is preserved")
        expect(decode(response("weather", []), "weather") == [], "No suggestions is a valid response")
        expect(decode(response("weather", (0..<20).map { "weather \($0)" }), "weather")?.count == 8, "Visible suggestion count is bounded")
        for root in [[], ["weather"], [7, []], ["different", ["weather radar"]], ["weather", 7], ["weather", NSNull()]] as [[Any]] {
            expect(decode(response(root: root, query: "weather"), "weather") == nil, "Malformed or mismatched JSON shape is rejected")
        }
        let good = response("weather", ["weather radar"])
        expect(decode(GoogleSuggestionResponse(data: Data("not JSON".utf8), url: good.url, statusCode: 200, mimeType: "application/json"), "weather") == nil, "Malformed JSON is rejected")
        expect(decode(GoogleSuggestionResponse(data: Data(repeating: 32, count: 65_537), url: good.url, statusCode: 200, mimeType: "application/json"), "weather") == nil, "Oversized response is rejected before JSON parsing")
        for status in [201, 301, 403, 429, 500] {
            expect(decode(GoogleSuggestionResponse(data: good.data, url: good.url, statusCode: status, mimeType: good.mimeType), "weather") == nil, "Non-200 response never produces suggestions")
        }
        for mime in [nil, "text/html", "image/png", "application/octet-stream"] as [String?] {
            expect(decode(GoogleSuggestionResponse(data: good.data, url: good.url, statusCode: 200, mimeType: mime), "weather") == nil, "Non-JSON content is rejected")
        }
        expect(decode(GoogleSuggestionResponse(data: good.data, url: URL(string: "https://evil.test/")!, statusCode: 200, mimeType: good.mimeType), "weather") == nil, "Response cannot change origin")
    }

    static func debounceAndCoalescing() {
        let transport = TestTransport(), scheduler = TestScheduler()
        let service = GoogleSuggestionsService(transport: transport, scheduler: scheduler.schedule)
        var output: [GoogleSuggestionResult] = []
        service.suggestions(for: "weather") { output.append($0) }
        expect(scheduler.jobs.count == 1 && abs(scheduler.jobs[0].delay - 0.18) < 0.001 && transport.transfers.isEmpty, "Typing is debounced without immediate request")
        service.suggestions(for: "weather radar") { output.append($0) }
        expect(scheduler.jobs[0].cancellation.cancelled, "Changed query cancels previous debounce")
        scheduler.fire(0, evenIfCancelled: true)
        expect(transport.transfers.isEmpty, "Late cancelled scheduler cannot start a request")
        service.suggestions(for: " weather radar ") { output.append($0) }
        expect(scheduler.jobs.count == 2, "Duplicate normalized pending query shares the debounce")
        scheduler.fire(1)
        expect(transport.transfers.count == 1 && transport.transfers[0].query == "weather radar", "Only latest query reaches transport")
        service.suggestions(for: "weather radar") { output.append($0) }
        expect(transport.transfers.count == 1, "Duplicate in-flight query shares a transfer")
        transport.succeed(0, ["weather radar live"])
        expect(output.count == 3 && output.allSatisfy { $0.query == "weather radar" && $0.suggestions == ["weather radar live"] }, "Every current-query subscriber receives tied results once")
        service.suggestions(for: "weather radar") { output.append($0) }
        expect(output.count == 4 && scheduler.jobs.count == 2, "Cache hit is synchronous without another scheduled request")

        let synchronous = TestTransport(), immediateScheduler = TestScheduler()
        synchronous.immediate = response("weather", ["weather radar"])
        let immediateService = GoogleSuggestionsService(transport: synchronous, scheduler: immediateScheduler.schedule)
        var immediate = false
        immediateService.suggestions(for: "weather") { immediate = $0.suggestions == ["weather radar"] }
        immediateScheduler.fire(0)
        expect(immediate && synchronous.transfers[0].cancellation.cancelled, "Synchronous transport completion does not leave dangling transfer")
    }

    static func cancellationAndFailure() {
        let transport = TestTransport(), scheduler = TestScheduler()
        let service = GoogleSuggestionsService(transport: transport, scheduler: scheduler.schedule)
        var output: [GoogleSuggestionResult] = []
        service.suggestions(for: "weather") { output.append($0) }
        scheduler.fire(0)
        service.suggestions(for: "maps") { output.append($0) }
        expect(transport.transfers[0].cancellation.cancelled, "New query cancels active network transfer")
        transport.succeed(0, ["obsolete"])
        expect(output.isEmpty, "Late old-query network response cannot reach UI")
        scheduler.fire(1)
        transport.succeed(1, ["maps near me"])
        expect(output.count == 1 && output[0].query == "maps", "Current response survives cancelled older response")
        service.suggestions(for: "weather") { output.append($0) }
        expect(scheduler.jobs.count == 3, "Cancelled obsolete response does not repopulate query cache")
        scheduler.fire(2)
        service.cancel()
        expect(transport.transfers[2].cancellation.cancelled, "Closing palette cancels transfer")
        transport.succeed(2, ["late after close"])
        expect(output.count == 1, "Closing palette suppresses late results")
        service.suggestions(for: "new query") { output.append($0) }
        service.cancel()
        scheduler.fire(3, evenIfCancelled: true)
        expect(transport.transfers.count == 3, "Closing palette cancels pending debounce")
        service.suggestions(for: "another query") { output.append($0) }
        scheduler.fire(4)
        service.suggestions(for: "https://private.example.com") { output.append($0) }
        expect(transport.transfers[3].cancellation.cancelled && output.last?.suggestions == [], "Address text stays local and cancels previous request")
        transport.succeed(3, ["late after address"])
        expect(output.count == 2, "Unsafe replacement query suppresses older response")

        service.suggestions(for: "offline query") { output.append($0) }
        scheduler.fire(5)
        transport.transfers[4].callback(.failure(URLError(.notConnectedToInternet)))
        expect(output.last?.query == "offline query" && output.last?.suggestions == [], "Offline suggestions fail softly with empty results")
        service.suggestions(for: "offline query") { output.append($0) }
        expect(scheduler.jobs.count == 7, "Transient failure is not cached")
        scheduler.fire(6)
        transport.transfers[5].callback(.success(response("different query", ["wrong response"])))
        expect(output.last?.suggestions == [], "Mismatched provider response fails softly")

        service.suggestions(for: "thread query") { output.append($0); expect(Thread.isMainThread, "Network completion is marshalled to main thread") }
        scheduler.fire(7)
        let callback = transport.transfers[6].callback
        DispatchQueue.global().async { callback(.success(response("thread query", ["thread query result"]))) }
        spinUntil { output.last?.query == "thread query" }
        expect(output.last?.suggestions == ["thread query result"], "Background response delivers successfully")
    }

    static func cachePolicy() {
        var date = Date(timeIntervalSince1970: 1_000)
        let transport = TestTransport(), scheduler = TestScheduler()
        var configuration = GoogleSuggestionsService.Configuration()
        configuration.cacheTTL = 10
        configuration.maximumCacheEntries = 2
        let service = GoogleSuggestionsService(transport: transport, now: { date }, configuration: configuration, scheduler: scheduler.schedule)
        var values: [GoogleSuggestionResult] = []
        func load(_ query: String, _ suggestions: [String]) {
            service.suggestions(for: query) { values.append($0) }
            scheduler.fire(scheduler.jobs.count - 1)
            transport.succeed(transport.transfers.count - 1, suggestions)
        }
        load("alpha", ["alpha result"])
        load("beta", [])
        let before = scheduler.jobs.count
        service.suggestions(for: "beta") { values.append($0) }
        expect(scheduler.jobs.count == before && values.last?.suggestions == [], "Valid empty completion response is cached")
        service.suggestions(for: "alpha") { values.append($0) }
        load("gamma", ["gamma result"])
        service.suggestions(for: "alpha") { values.append($0) }
        expect(scheduler.jobs.count == before + 1 && values.last?.suggestions == ["alpha result"], "Recently used entry survives bounded LRU eviction")
        service.suggestions(for: "beta") { values.append($0) }
        expect(scheduler.jobs.count == before + 2, "Least recently used entry is evicted")
        service.cancel()
        date.addTimeInterval(10)
        service.suggestions(for: "alpha") { values.append($0) }
        expect(scheduler.jobs.count == before + 3, "Cache expires exactly at TTL boundary")
        scheduler.fire(scheduler.jobs.count - 1)
        transport.succeed(transport.transfers.count - 1, ["new alpha"])
        date.addTimeInterval(-1)
        service.suggestions(for: "alpha") { values.append($0) }
        expect(scheduler.jobs.count == before + 4, "Clock rollback cannot retain cache indefinitely")
        scheduler.fire(scheduler.jobs.count - 1)
        transport.succeed(transport.transfers.count - 1, ["reset alpha"])
        service.clearCache()
        service.suggestions(for: "alpha") { values.append($0) }
        expect(scheduler.jobs.count == before + 5, "Clear removes remembered provider queries")
        service.cancel()
    }

    static func transportPolicy() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuggestionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "must-not-send", "Authorization": "must-not-send", "Referer": "must-not-send"]
        let transport = GoogleSuggestionsURLTransport(configuration: configuration)
        var captured: URLRequest?
        SuggestionURLProtocol.handler = { stub in
            let request = stub.request
            DispatchQueue.main.async { captured = request }
            stub.reply(chunks: [response("weather", ["weather radar"]).data])
        }
        var result: Result<GoogleSuggestionResponse, Error>?
        let receive: (Result<GoogleSuggestionResponse, Error>) -> Void = { value in
            if Thread.isMainThread { result = value } else { DispatchQueue.main.async { result = value } }
        }
        _ = transport.fetch(query: "weather", completion: receive)
        spinUntil { result != nil }
        expect((try? result?.get().statusCode) == 200, "URLSession transport handles synthetic JSON without network")
        expect(captured?.value(forHTTPHeaderField: "Cookie") == nil && captured?.value(forHTTPHeaderField: "Authorization") == nil && captured?.value(forHTTPHeaderField: "Referer") == nil, "Supplied configuration cannot introduce cookies, credentials or referrer")

        for status in [301, 403, 429, 500] {
            result = nil
            SuggestionURLProtocol.handler = { $0.reply(status: status, chunks: [Data()]) }
            _ = transport.fetch(query: "weather", completion: receive)
            spinUntil { result != nil }
            expect(isFailure(result), "Transport rejects HTTP \(status)")
        }
        result = nil
        SuggestionURLProtocol.handler = { $0.reply(chunks: [Data()], length: 65_537) }
        _ = transport.fetch(query: "weather", completion: receive)
        spinUntil { result != nil }
        expect(isFailure(result), "Oversized Content-Length is rejected without buffering body")
        result = nil
        SuggestionURLProtocol.handler = { $0.reply(chunks: [Data(repeating: 32, count: 40_000), Data(repeating: 32, count: 40_000)]) }
        _ = transport.fetch(query: "weather", completion: receive)
        spinUntil { result != nil }
        expect(isFailure(result), "Streaming response is cancelled at byte limit even without Content-Length")

        let redirectURL = URL(string: "https://evil.test/")!
        var allowedRedirect: URLRequest? = URLRequest(url: redirectURL)
        let task = URLSession.shared.dataTask(with: URL(string: "https://suggestqueries.google.com/")!)
        transport.urlSession(URLSession.shared, task: task,
                             willPerformHTTPRedirection: HTTPURLResponse(url: redirectURL, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                             newRequest: URLRequest(url: redirectURL)) { allowedRedirect = $0 }
        expect(allowedRedirect == nil, "Transport rejects every redirect including cross-origin redirect")
        task.cancel()

        result = nil
        _ = transport.fetch(query: "https://private.example.com", completion: receive)
        expect(isFailure(result), "Unsafe query fails synchronously without URLSession request")
        result = nil
        SuggestionURLProtocol.handler = { _ in }
        let cancellable = transport.fetch(query: "weather", completion: receive)
        cancellable.cancel()
        spinUntil { result != nil }
        expect(isFailure(result), "Cancellation terminates the transport")
        SuggestionURLProtocol.handler = nil
    }

    static func response(_ query: String, _ values: [String]) -> GoogleSuggestionResponse {
        response(root: [query, values], query: query)
    }

    static func response(root: [Any], query: String) -> GoogleSuggestionResponse {
        GoogleSuggestionResponse(data: try! JSONSerialization.data(withJSONObject: root),
                                 url: GoogleSuggestionsURLTransport.request(query: query)!.url!, statusCode: 200, mimeType: "application/json")
    }

    static func decode(_ response: GoogleSuggestionResponse, _ query: String) -> [String]? {
        try? GoogleSuggestionDecoder.decode(response, query: query)
    }

    static func isFailure(_ result: Result<GoogleSuggestionResponse, Error>?) -> Bool {
        if case .failure? = result { return true }
        return false
    }

    static func spinUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), "Timed out waiting for deterministic asynchronous completion")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
}

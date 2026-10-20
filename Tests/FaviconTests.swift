import AppKit
import Foundation

private enum TestFailure: Error { case missing }

private final class FakeFaviconTransport: FaviconTransport {
    private let lock = NSLock()
    var hold = false
    private var responses: [String: Result<FaviconResponse, Error>] = [:]
    private var callbacks: [(URL, (Result<FaviconResponse, Error>) -> Void)] = []
    private var requests: [URL] = []

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requests }
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }

    func set(_ url: String, data: Data, mime: String? = "image/png", status: Int = 200, responseURL: String? = nil) {
        lock.lock()
        responses[url] = .success(FaviconResponse(data: data, url: URL(string: responseURL ?? url)!, statusCode: status, mimeType: mime))
        lock.unlock()
    }

    func fetch(_ url: URL, completion: @escaping (Result<FaviconResponse, Error>) -> Void) {
        lock.lock()
        requests.append(url)
        if hold { callbacks.append((url, completion)); lock.unlock(); return }
        let result = responses[url.absoluteString] ?? .failure(TestFailure.missing)
        lock.unlock()
        completion(result)
    }

    func completeNext() {
        lock.lock()
        guard !callbacks.isEmpty else { lock.unlock(); return }
        let (url, completion) = callbacks.removeFirst()
        let result = responses[url.absoluteString] ?? .failure(TestFailure.missing)
        lock.unlock()
        completion(result)
    }
}

private final class FakeClock {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); date.addTimeInterval(interval); lock.unlock() }
}

private final class FaviconProtocolStub: URLProtocol {
    static var response: HTTPURLResponse!
    static var chunks: [Data] = []
    static var seen: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = request
        client?.urlProtocol(self, didReceive: Self.response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct FaviconTests {
    static var checks = 0
    static var directories: [URL] = []

    static func main() throws {
        defer { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
        try originsAndHTML()
        try imagesAndPrivacy()
        try expirationAndPersistence()
        try coalescingAndConcurrency()
        try boundedAndCorruptCache()
        try nativeTransport()
        try localIcons()
        print("Passed \(checks) favicon checks")
    }

    static func originsAndHTML() throws {
        expect(FaviconOrigin("HTTPS://EXAMPLE.COM:443/a?private=1#x")?.key == "https://example.com", "Canonical origin discards page path/query/fragment/default port")
        expect(FaviconOrigin("http://example.com:8080/path")?.key == "http://example.com:8080", "Nondefault port kept in origin")
        expect(FaviconOrigin("https://example.com.") == FaviconOrigin("https://example.com"), "Trailing host dot canonicalized")
        for url in ["file:///tmp/a", "data:image/png;base64,AAA", "about:blank", "https://name:secret@example.com/a", "http://localhost:3000", "http://router", "http://dev.local", "http://app.internal", "http://10.1.2.3", "http://172.16.1.1", "http://192.168.0.1", "http://127.0.0.1", "http://169.254.1.1", "http://100.64.1.1", "http://[::1]", "http://127.1", "http://0x7f.0.0.1", "http://0177.0.0.1", "http://127.000.0.1", "http://0x7f.0x00.0x00.0x01", "http://2130706433", "http://0x7f000001"] {
            expect(FaviconOrigin(url) == nil, "Unsafe or local URL is not fetched: \(url)")
        }
        expect(FaviconOrigin("https://example.com")?.accepts(URL(string: "https://elsewhere.com/icon.png")!) == false, "Icon origin cannot change")
        expect(FaviconOrigin("https://example.com")?.accepts(URL(string: "http://example.com/icon.png")!) == false, "Icon protocol cannot change")
        let origin = FaviconOrigin("https://example.com/private")!
        let html = Data("""
        <HTML><HEAD><link rel=apple-touch-icon href='/touch.png'>
        <LINK rel='SHORTCUT ICON' href='/mark.png?v=2&amp;x=3#ignored'>
        <link rel=icon href='https://tracker.example.org/favicon.png'>
        <link rel=icon href='data:image/png;base64,abc'>
        <link rel=icon href='/mark.png?v=2&amp;x=3'><link rel=stylesheet href='/style.css'>
        </HEAD><BODY>not closed
        """.utf8)
        let candidates = FaviconHTML.candidates(in: html, origin: origin)
        expect(candidates.map(\.absoluteString) == ["https://example.com/mark.png?v=2&x=3", "https://example.com/touch.png"], "Native HTML parser handles case/entities/unquoted attributes, filters and deduplicates")
        let many = Data(("<html><head>" + (0..<10).map { "<link rel=icon href='/\($0).png'>" }.joined() + "</head></html>").utf8)
        expect(FaviconHTML.candidates(in: many, origin: origin).count == 4, "Limit custom icon candidates")
        expect(FaviconHTML.candidates(in: Data(repeating: 65, count: FaviconURLTransport.maximumBytes + 1), origin: origin).isEmpty, "Oversized HTML not parsed")
    }

    static func imagesAndPrivacy() throws {
        let png = try fixturePNG(width: 128, height: 64)
        let transport = FakeFaviconTransport()
        transport.set("https://example.com/", data: Data("<html><head><link rel=icon href='/brand.png'></head></html>".utf8), mime: "text/html")
        transport.set("https://example.com/brand.png", data: png)
        let directory = temporaryDirectory()
        let store = FaviconStore(transport: transport, directory: directory)
        expect(store.imageFor(url: "https://example.com/private?secret=yes") == nil, "Cold synchronous lookup does not fetch or read disk")
        expect(transport.urls.isEmpty, "Memory lookup starts no request")
        let image = fetch(store, "https://example.com/private?secret=yes")
        expect(image?.size == NSSize(width: 64, height: 32), "PNG thumbnail has bounded Retina-ready pixels and preserves aspect")
        expect(transport.urls.map(\.absoluteString) == ["https://example.com/", "https://example.com/brand.png"], "Only root and discovered favicon requested, never tab path or query")
        expect(store.imageFor(url: "https://example.com/another") != nil, "Same-origin memory image shared across tab paths")
        _ = fetch(store, "https://example.com/another")
        expect(transport.urls.count == 2, "Positive cache avoids all repeated network work")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        expect(files.count == 1 && files[0].deletingPathExtension().lastPathComponent == FaviconOrigin("https://example.com")!.cacheKey, "Disk filenames are origin hashes")
        let disk = try String(contentsOf: files[0], encoding: .utf8)
        expect(!disk.contains("example.com") && !disk.contains("secret") && !disk.contains("private"), "Persistent records contain no origin/tab URLs")

        let icoTransport = FakeFaviconTransport()
        icoTransport.set("https://ico.example.com/favicon.ico", data: fixtureICO(png, width: 128, height: 64), mime: "image/x-icon")
        let ico = fetch(FaviconStore(transport: icoTransport, directory: temporaryDirectory()), "https://ico.example.com/path")
        expect(ico?.size == NSSize(width: 64, height: 32), "ICO format decoded and Retina-ready aspect preserved")

        let broken = FakeFaviconTransport()
        broken.set("https://broken.example.com/", data: Data("<html><link rel=icon href='/bad.png'><link rel=icon href='/good.png'>".utf8), mime: "text/html")
        broken.set("https://broken.example.com/bad.png", data: Data("not an image".utf8))
        broken.set("https://broken.example.com/good.png", data: png)
        expect(fetch(FaviconStore(transport: broken, directory: temporaryDirectory()), "https://broken.example.com") != nil, "Invalid preferred icon falls through to next icon")

        let invalid = FakeFaviconTransport()
        invalid.set("https://bad.example.com/favicon.ico", data: Data("<html>404</html>".utf8), mime: "text/html")
        let invalidStore = FaviconStore(transport: invalid, directory: temporaryDirectory())
        expect(fetch(invalidStore, "https://bad.example.com") == nil, "Invalid bytes leave caller generic fallback")
        expect(fetch(invalidStore, "file:///tmp/favicon.png") == nil, "Unsafe request has main-thread nil completion")
        expect(invalid.urls.count == 2, "Unsafe request does not reach transport")
    }

    static func expirationAndPersistence() throws {
        let png = try fixturePNG(width: 32, height: 32)
        let clock = FakeClock()
        var configuration = FaviconStore.Configuration()
        configuration.positiveTTL = 100
        configuration.negativeTTL = 10
        let transport = FakeFaviconTransport()
        transport.set("https://cache.example.com/favicon.ico", data: png)
        let directory = temporaryDirectory()
        let store = FaviconStore(transport: transport, directory: directory, clock: clock.now, configuration: configuration)
        expect(fetch(store, "https://cache.example.com") != nil, "Populate positive cache")
        let restoredTransport = FakeFaviconTransport()
        let restored = FaviconStore(transport: restoredTransport, directory: directory, clock: clock.now, configuration: configuration)
        expect(fetch(restored, "https://cache.example.com/next") != nil && restoredTransport.urls.isEmpty, "New instance restores persistent icon without network")
        clock.advance(101)
        expect(store.imageFor(url: "https://cache.example.com") == nil, "Expired image never returned by synchronous lookup")
        expect(fetch(store, "https://cache.example.com") != nil && transport.urls.count == 4, "Positive TTL expires and reloads origin")

        let missingTransport = FakeFaviconTransport()
        let negativeDirectory = temporaryDirectory()
        let missing = FaviconStore(transport: missingTransport, directory: negativeDirectory, clock: clock.now, configuration: configuration)
        expect(fetch(missing, "https://missing.example.com") == nil, "Cache missing icons")
        expect(fetch(missing, "https://missing.example.com/a") == nil && missingTransport.urls.count == 2, "Negative cache suppresses retries")
        let negativeRestoredTransport = FakeFaviconTransport()
        let negativeRestored = FaviconStore(transport: negativeRestoredTransport, directory: negativeDirectory, clock: clock.now, configuration: configuration)
        expect(fetch(negativeRestored, "https://missing.example.com") == nil && negativeRestoredTransport.urls.isEmpty, "Negative cache survives relaunch")
        clock.advance(11)
        _ = fetch(missing, "https://missing.example.com")
        expect(missingTransport.urls.count == 4, "Negative TTL expires independently")
    }

    static func coalescingAndConcurrency() throws {
        let png = try fixturePNG(width: 16, height: 16)
        let transport = FakeFaviconTransport()
        transport.hold = true
        for host in ["one", "two", "three"] { transport.set("https://\(host).example.com/favicon.ico", data: png) }
        var configuration = FaviconStore.Configuration()
        configuration.maximumConcurrentOrigins = 2
        let store = FaviconStore(transport: transport, directory: temporaryDirectory(), configuration: configuration)
        var callbacks = 0
        for _ in 0..<12 {
            store.request(url: "https://one.example.com/path") { image in
                expect(Thread.isMainThread && image != nil, "Coalesced completion main-thread image")
                callbacks += 1
            }
        }
        store.request(url: "https://two.example.com") { _ in callbacks += 1 }
        store.request(url: "https://three.example.com") { _ in callbacks += 1 }
        spin { transport.outstanding == 2 }
        expect(transport.urls.count == 2 && !transport.urls.contains(URL(string: "https://three.example.com/")!), "Concurrent origin limit queues excess work")
        while callbacks < 14 {
            spin { transport.outstanding > 0 || callbacks == 14 }
            if transport.outstanding > 0 { transport.completeNext() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            expect(transport.outstanding <= 2, "Concurrency bound maintained across HTML/icon/fallback stages")
        }
        expect(transport.urls.count == 6, "Twelve same-origin requests coalesce to one root plus one icon")
    }

    static func boundedAndCorruptCache() throws {
        let png = try fixturePNG(width: 16, height: 16)
        let clock = FakeClock()
        var configuration = FaviconStore.Configuration()
        configuration.maximumEntries = 2
        let transport = FakeFaviconTransport()
        for host in ["a", "b", "c"] { transport.set("https://\(host).example.com/favicon.ico", data: png) }
        let directory = temporaryDirectory()
        let store = FaviconStore(transport: transport, directory: directory, clock: clock.now, configuration: configuration)
        _ = fetch(store, "https://a.example.com")
        clock.advance(1)
        _ = fetch(store, "https://b.example.com")
        clock.advance(1)
        expect(store.imageFor(url: "https://a.example.com") != nil, "Immediate image access touches memory LRU without network")
        clock.advance(1)
        _ = fetch(store, "https://c.example.com")
        expect(store.imageFor(url: "https://b.example.com") == nil && store.imageFor(url: "https://a.example.com") != nil, "Least recently used entry evicted, including immediate image lookups")
        try expect(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2, "Disk entries bounded with memory entries")

        let oversized = FakeFaviconTransport()
        oversized.set("https://large.example.com/favicon.ico", data: Data(repeating: 0, count: FaviconURLTransport.maximumBytes + 1))
        expect(fetch(FaviconStore(transport: oversized, directory: temporaryDirectory()), "https://large.example.com") == nil, "Oversized icon rejected even from injected transport")
        let huge = FakeFaviconTransport()
        huge.set("https://huge.example.com/favicon.ico", data: try fixturePNG(width: 4097, height: 1))
        expect(fetch(FaviconStore(transport: huge, directory: temporaryDirectory()), "https://huge.example.com") == nil, "Excess pixel dimensions rejected before image decode")
        let redirect = FakeFaviconTransport()
        redirect.set("https://redirect.example.com/favicon.ico", data: png, responseURL: "https://thirdparty.example.com/icon.png")
        expect(fetch(FaviconStore(transport: redirect, directory: temporaryDirectory()), "https://redirect.example.com") == nil, "Cross-origin final icon response rejected")

        let corruptDirectory = temporaryDirectory()
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corrupt = corruptDirectory.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try Data("broken".utf8).write(to: corrupt)
        let corruptedTransport = FakeFaviconTransport()
        let corruptedStore = FaviconStore(transport: corruptedTransport, directory: corruptDirectory)
        _ = fetch(corruptedStore, "https://corrupt.example.com")
        expect(!FileManager.default.fileExists(atPath: corrupt.path), "Corrupt disk records removed without breaking request")
    }

    static func nativeTransport() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconProtocolStub.self]
        let transport = FaviconURLTransport(configuration: configuration)
        let url = URL(string: "https://transport.example.com/favicon.ico")!
        let png = try fixturePNG(width: 16, height: 16)
        FaviconProtocolStub.response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png", "Content-Length": String(png.count)])!
        FaviconProtocolStub.chunks = [png]
        var result = transportFetch(transport, url)
        if case .success(let response) = result {
            expect(response.data == png && response.statusCode == 200 && response.mimeType == "image/png", "Native transport returns bounded image response")
        } else { fatalError("Native transport should succeed") }
        let request = FaviconProtocolStub.seen!
        expect(request.httpShouldHandleCookies == false && request.value(forHTTPHeaderField: "Cookie") == nil, "Native request never sends cookies")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Referer") == nil, "Native request sends no credentials or referrer")
        expect(request.timeoutInterval == 8 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Native request has bounded timeout and bypasses shared HTTP cache")
        FaviconProtocolStub.response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        result = transportFetch(transport, url)
        expect(isFailure(result), "Native transport rejects error HTTP status")
        FaviconProtocolStub.response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(FaviconURLTransport.maximumBytes + 1)])!
        result = transportFetch(transport, url)
        expect(isFailure(result), "Native transport rejects advertised oversized response before buffering")
        FaviconProtocolStub.response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        FaviconProtocolStub.chunks = [Data(repeating: 0, count: FaviconURLTransport.maximumBytes / 2), Data(repeating: 0, count: FaviconURLTransport.maximumBytes / 2 + 1)]
        result = transportFetch(transport, url)
        expect(isFailure(result), "Native streaming transport caps bodies without Content-Length")
        FaviconProtocolStub.response = HTTPURLResponse(url: URL(string: "https://elsewhere.example.com/icon")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        FaviconProtocolStub.chunks = [png]
        result = transportFetch(transport, url)
        expect(isFailure(result), "Native transport rejects cross-origin response independently of store")
        result = transportFetch(transport, URL(string: "http://127.0.0.1/favicon.ico")!)
        expect(isFailure(result), "Native transport refuses unsafe URL before URLSession")
    }

    static func localIcons() throws {
        let transport = FakeFaviconTransport()
        let store = FaviconStore(transport: transport, directory: temporaryDirectory(), clock: FakeClock().now)
        let png = try fixturePNG(width: 32, height: 32)
        expect(store.useLocalIcons(["https://mail.example": png, "https://broken.example": Data("not an image".utf8),
                                    "http://localhost:3000": png]), "A new set of browser icons is reported as a change")
        expect(store.imageFor(url: "https://mail.example/inbox?x=1") != nil, "A browser's icon is shown at once for any page of its site")
        expect(fetch(store, "https://MAIL.example:443/sent") != nil && transport.urls.isEmpty,
               "A browser's icon is used without downloading anything")
        expect(fetch(store, "https://broken.example/") == nil && transport.urls.map(\.host).contains("broken.example"),
               "Unreadable icon data falls back to downloading the site's icon")
        expect(store.imageFor(url: "http://localhost:3000/") == nil, "Private addresses get no icon from a browser either")
        expect(!store.useLocalIcons(["https://mail.example": png, "https://broken.example": Data("not an image".utf8),
                                     "http://localhost:3000": png]), "The same set again changes nothing")
        store.useLocalIcons([:])
        expect(store.imageFor(url: "https://mail.example/inbox") == nil, "Icons of a browser profile turned off disappear")
    }

    static func transportFetch(_ transport: FaviconTransport, _ url: URL) -> Result<FaviconResponse, Error> {
        let lock = NSLock()
        var result: Result<FaviconResponse, Error>?
        transport.fetch(url) { response in lock.lock(); result = response; lock.unlock() }
        spin { lock.lock(); defer { lock.unlock() }; return result != nil }
        lock.lock(); defer { lock.unlock() }
        return result!
    }

    static func isFailure(_ result: Result<FaviconResponse, Error>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    static func fetch(_ store: FaviconStore, _ url: String) -> NSImage? {
        var completed = false
        var result: NSImage?
        store.request(url: url) { image in
            expect(Thread.isMainThread, "Completion delivered on main thread")
            result = image
            completed = true
        }
        spin { completed }
        return result
    }

    static func fixturePNG(width: Int, height: Int) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let pixels = bitmap.bitmapData!
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            pixels[offset] = 20; pixels[offset + 1] = 130; pixels[offset + 2] = 220; pixels[offset + 3] = 255
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func fixtureICO(_ png: Data, width: Int, height: Int) -> Data {
        var bytes: [UInt8] = [0, 0, 1, 0, 1, 0, UInt8(width), UInt8(height), 0, 0, 1, 0, 32, 0]
        for value in [UInt32(png.count), UInt32(22)] {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> shift) & 255)) }
        }
        return Data(bytes) + png
    }

    static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabScoutFaviconTests-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return directory
    }

    static func spin(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        expect(condition(), "Asynchronous operation completed before test deadline")
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        if try !condition() { fatalError(message) }
    }
}

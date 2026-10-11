import Foundation
import SQLite3

struct HistoryVisit: Codable, Equatable {
    let url: String
    let title: String
    let lastVisited: Date
    let visitCount: Int
}

struct PastSearch: Codable, Equatable {
    let query: String
    let lastUsed: Date
    let useCount: Int
}

struct HistorySnapshot: Codable, Equatable {
    var visits: [HistoryVisit]
    var searches: [PastSearch]

    static let empty = HistorySnapshot(visits: [], searches: [])
}

enum HistoryError: Error, LocalizedError, Equatable {
    case needsPermission
    case unavailable
    case invalidDatabase
    case storage

    var errorDescription: String? {
        switch self {
        case .needsPermission: return "Allow Tab Scout Full Disk Access to use Safari history."
        case .unavailable: return "Safari history is unavailable. Tab Scout choices can still be used."
        case .invalidDatabase: return "Safari history has an unsupported or unreadable format."
        case .storage: return "Tab Scout could not read or save its local choices."
        }
    }
}

enum HistoryIdentity {
    static func query(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let folded = compact.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX"))
        return folded.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? folded
    }

    static func url(_ text: String) -> String? {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }
}

enum HistorySearchQuery {
    // Restrict extraction to known Google search hosts, not user-controlled subdomains.
    private static let domains: Set<String> = [
        "google.com", "google.pl", "google.co.uk", "google.de", "google.fr", "google.es",
        "google.it", "google.nl", "google.be", "google.at", "google.ch", "google.cz",
        "google.sk", "google.pt", "google.se", "google.no", "google.dk", "google.fi",
        "google.ie", "google.hu", "google.ro", "google.gr", "google.com.au", "google.co.nz",
        "google.ca", "google.co.jp", "google.co.in", "google.com.br", "google.com.mx",
        "google.co.za", "google.com.sg", "google.com.hk", "google.co.kr", "google.com.tr"
    ]

    static func from(url: String) -> String? {
        guard var components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let rawHost = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 80 || components.port == 443,
              components.path == "/search" else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard domains.contains(host) else { return nil }
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%20")
        }
        let queries = (components.queryItems ?? []).filter { $0.name == "q" }
        guard queries.count == 1, let value = queries[0].value else { return nil }
        return cleaned(value)
    }

    static func cleaned(_ value: String) -> String? {
        guard value.count <= 512, !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        let query = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return query.isEmpty ? nil : query
    }
}

// Main-thread owned. Only the serial worker touches files and SQLite connections.
final class HistoryStore {
    static let retention: TimeInterval = 183 * 24 * 60 * 60
    static let maximumSafariRows = 10_000
    static let maximumVisits = 5_000
    static let maximumLocalVisits = 1_000
    static let maximumSearches = 500
    private static let maximumCount = 100_000

    private struct Persisted: Codable {
        let version: Int
        let snapshot: HistorySnapshot
    }

    private struct LoadKey: Hashable {
        let includeSafari: Bool
        let generation: Int
    }

    private let directory: URL
    private let safariDBURL: URL
    private let freshFor: TimeInterval
    private let now: () -> Date
    private let safariReader: (URL, Date) throws -> HistorySnapshot
    private let queue = DispatchQueue(label: "local.tabscout.history", qos: .utility)
    private var local = HistorySnapshot.empty
    private var safari = HistorySnapshot.empty
    private var localLoaded = false
    private var requestedSafari = false
    private var localLoadedAt: Date?
    private var safariLoadedAt: Date?
    private var mergedSnapshot: HistorySnapshot?
    private var mergedAt: Date?
    private var mutationVersion = 0
    private var safariGeneration = 0
    private var waiters: [LoadKey: [(Result<HistorySnapshot, Error>) -> Void]] = [:]
    private(set) var localStorageError: HistoryError?
    // Accessed only by queue.
    private var storedLocal: HistorySnapshot?
    private var storedLocalError: HistoryError?

    init(directory: URL? = nil, safariDBURL: URL? = nil, freshFor: TimeInterval = 30,
         now: @escaping () -> Date = Date.init,
         safariReader: @escaping (URL, Date) throws -> HistorySnapshot = HistoryStore.readSafari) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabScout/History", isDirectory: true)
        self.safariDBURL = safariDBURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db")
        self.freshFor = freshFor
        self.now = now
        self.safariReader = safariReader
    }

    var snapshot: HistorySnapshot {
        let date = now()
        if let mergedSnapshot, let mergedAt, date.timeIntervalSince(mergedAt) >= 0,
           date.timeIntervalSince(mergedAt) < freshFor { return mergedSnapshot }
        let result = Self.merge(local, requestedSafari ? safari : .empty, now: date)
        mergedSnapshot = result
        mergedAt = date
        return result
    }

    func load(includeSafari: Bool, completion: @escaping (Result<HistorySnapshot, Error>) -> Void) {
        precondition(Thread.isMainThread)
        if requestedSafari != includeSafari { mergedSnapshot = nil }
        if requestedSafari && !includeSafari {
            safariGeneration += 1
            safari = .empty
            safariLoadedAt = nil
        }
        requestedSafari = includeSafari
        let date = now()
        let loadedAt = includeSafari ? safariLoadedAt : localLoadedAt
        if localLoaded, let loadedAt, date.timeIntervalSince(loadedAt) >= 0,
           date.timeIntervalSince(loadedAt) < freshFor {
            if !includeSafari, let localStorageError { completion(.failure(localStorageError)); return }
            completion(.success(snapshot))
            return
        }
        let key = LoadKey(includeSafari: includeSafari, generation: safariGeneration)
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        let version = mutationVersion
        queue.async { [weak self] in
            guard let self else { return }
            let stored: Result<HistorySnapshot, Error> = Result { try self.loadLocal(now: date) }
            let imported: Result<HistorySnapshot, Error> = includeSafari
                ? Result { try self.safariReader(self.safariDBURL, date) } : .success(.empty)
            let localError = self.storedLocalError
            DispatchQueue.main.async {
                if case .success(let saved) = stored {
                    if version == self.mutationVersion { self.local = saved }
                }
                if version == self.mutationVersion { self.localStorageError = localError }
                self.localLoaded = true
                self.localLoadedAt = date
                let currentGeneration = key.generation == self.safariGeneration
                if includeSafari && self.requestedSafari && currentGeneration {
                    if case .success(let imported) = imported {
                        self.safari = imported
                        self.safariLoadedAt = date
                    } else {
                        self.safari = .empty
                        self.safariLoadedAt = nil
                    }
                }
                self.mergedSnapshot = nil
                let result: Result<HistorySnapshot, Error> = !includeSafari && localError != nil
                    ? .failure(localError!) : imported.map { imported in
                    includeSafari == self.requestedSafari && currentGeneration ? self.snapshot
                        : Self.merge(self.local, includeSafari ? imported : .empty, now: self.now())
                }
                let callbacks = self.waiters.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(result) }
            }
        }
    }

    func recordVisit(url: String, title: String) {
        precondition(Thread.isMainThread)
        guard let url = HistoryIdentity.url(url) else { return }
        let date = now()
        let event = HistorySnapshot(visits: [HistoryVisit(url: url, title: String(title.prefix(1_024)),
                                                         lastVisited: date, visitCount: 1)], searches: [])
        record(event, at: date)
    }

    func recordSearch(query: String) {
        precondition(Thread.isMainThread)
        guard let query = HistorySearchQuery.cleaned(query) else { return }
        let date = now()
        record(HistorySnapshot(visits: [], searches: [PastSearch(query: query, lastUsed: date, useCount: 1)]), at: date)
    }

    func clearLocal() {
        precondition(Thread.isMainThread)
        mutationVersion += 1
        let version = mutationVersion
        local = .empty
        mergedSnapshot = nil
        localLoadedAt = nil
        localStorageError = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.storedLocal = .empty
            self.storedLocalError = nil
            if FileManager.default.fileExists(atPath: self.localFile.path) {
                do { try FileManager.default.removeItem(at: self.localFile) }
                catch { self.storedLocalError = .storage }
            }
            let error = self.storedLocalError
            DispatchQueue.main.async {
                if version == self.mutationVersion { self.local = .empty; self.localStorageError = error }
            }
        }
    }

    private var localFile: URL { directory.appendingPathComponent("choices-v1.json") }

    private func record(_ event: HistorySnapshot, at date: Date) {
        mutationVersion += 1
        let version = mutationVersion
        local = Self.merge(local, event, now: date, localOnly: true, additive: true)
        mergedSnapshot = nil
        localLoadedAt = nil
        queue.async { [weak self] in
            guard let self else { return }
            // A malformed local file must not prevent new choices from being remembered.
            let previous = (try? self.loadLocal(now: date)) ?? .empty
            let updated = Self.merge(previous, event, now: date, localOnly: true, additive: true)
            self.storedLocal = updated
            do { try self.saveLocal(updated); self.storedLocalError = nil }
            catch { self.storedLocalError = .storage }
            let error = self.storedLocalError
            DispatchQueue.main.async {
                if version == self.mutationVersion { self.local = updated; self.localStorageError = error }
                self.localLoaded = true
                self.mergedSnapshot = nil
            }
        }
    }

    private func loadLocal(now date: Date) throws -> HistorySnapshot {
        if let storedLocal { return storedLocal }
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            storedLocal = .empty
            storedLocalError = nil
            return .empty
        }
        do {
            let size = try localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4 * 1_024 * 1_024 else { throw HistoryError.storage }
            let persisted = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: localFile))
            guard persisted.version == 1 else { throw HistoryError.storage }
            let cleaned = Self.merge(persisted.snapshot, .empty, now: date, localOnly: true)
            storedLocal = cleaned
            storedLocalError = nil
            if cleaned != persisted.snapshot {
                do { try saveLocal(cleaned) }
                catch { storedLocalError = .storage }
            }
            return cleaned
        } catch { storedLocalError = .storage; throw HistoryError.storage }
    }

    private func saveLocal(_ snapshot: HistorySnapshot) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(Persisted(version: 1, snapshot: snapshot))
            // The staging file is private from creation; replacement never exposes history to other users.
            let temporary = directory.appendingPathComponent(".choices-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                  attributes: [.posixPermissions: 0o600]) else { throw HistoryError.storage }
            defer { try? FileManager.default.removeItem(at: temporary) }
            if rename(temporary.path, localFile.path) != 0 { throw HistoryError.storage }
        } catch { throw HistoryError.storage }
    }

    static func merge(_ first: HistorySnapshot, _ second: HistorySnapshot, now: Date,
                      localOnly: Bool = false, additive: Bool = false) -> HistorySnapshot {
        let cutoff = now.addingTimeInterval(-retention)
        var visits: [String: HistoryVisit] = [:]
        for visit in first.visits + second.visits {
            guard let key = HistoryIdentity.url(visit.url), visit.visitCount > 0,
                  visit.lastVisited >= cutoff, visit.lastVisited <= now else { continue }
            if let previous = visits[key] {
                let latest = visit.lastVisited > previous.lastVisited ? visit : previous
                let count = additive ? min(maximumCount, previous.visitCount + min(visit.visitCount, maximumCount))
                    : max(previous.visitCount, min(visit.visitCount, maximumCount))
                visits[key] = HistoryVisit(url: key, title: String(latest.title.prefix(1_024)),
                                           lastVisited: max(previous.lastVisited, visit.lastVisited), visitCount: count)
            } else {
                visits[key] = HistoryVisit(url: key, title: String(visit.title.prefix(1_024)),
                                           lastVisited: visit.lastVisited, visitCount: min(visit.visitCount, maximumCount))
            }
        }
        var searches: [String: PastSearch] = [:]
        for search in first.searches + second.searches {
            guard let query = HistorySearchQuery.cleaned(search.query), search.useCount > 0,
                  search.lastUsed >= cutoff, search.lastUsed <= now else { continue }
            let key = HistoryIdentity.query(query)
            if let previous = searches[key] {
                let latest = search.lastUsed > previous.lastUsed ? search : previous
                let count = additive ? min(maximumCount, previous.useCount + min(search.useCount, maximumCount))
                    : max(previous.useCount, min(search.useCount, maximumCount))
                searches[key] = PastSearch(query: HistorySearchQuery.cleaned(latest.query)!,
                                          lastUsed: max(previous.lastUsed, search.lastUsed), useCount: count)
            } else {
                searches[key] = PastSearch(query: query, lastUsed: search.lastUsed, useCount: min(search.useCount, maximumCount))
            }
        }
        return HistorySnapshot(visits: Array(visits.values.sorted {
            $0.lastVisited == $1.lastVisited ? $0.url < $1.url : $0.lastVisited > $1.lastVisited
        }.prefix(localOnly ? maximumLocalVisits : maximumVisits)), searches: Array(searches.values.sorted {
            $0.lastUsed == $1.lastUsed ? $0.query < $1.query : $0.lastUsed > $1.lastUsed
        }.prefix(maximumSearches)))
    }

    static func readSafari(at url: URL, now: Date) throws -> HistorySnapshot {
        precondition(!Thread.isMainThread, "Safari history reads must not block the main thread")
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw HistoryError.unavailable }
        } catch let error as HistoryError { throw error }
        catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError { throw HistoryError.unavailable }
            throw HistoryError.needsPermission
        }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            throw sqliteError(opened, database: database)
        }
        guard sqlite3_db_readonly(database, "main") == 1 else { throw HistoryError.invalidDatabase }
        sqlite3_busy_timeout(database, 100)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let budget = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        budget.initialize(to: deadline)
        defer { sqlite3_progress_handler(database, 0, nil, nil); budget.deinitialize(count: 1); budget.deallocate() }
        sqlite3_progress_handler(database, 10_000, { context in
            guard let context else { return 1 }
            return DispatchTime.now().uptimeNanoseconds > context.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
        }, budget)
        let sql = """
        SELECT items.url, COALESCE(visits.title, ''), visits.visit_time
        FROM history_visits AS visits JOIN history_items AS items ON items.id = visits.history_item
        WHERE visits.visit_time >= ? AND visits.visit_time <= ?
        ORDER BY visits.visit_time DESC, visits.id DESC LIMIT ?
        """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(prepared, database: database)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-retention).timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 2, now.timeIntervalSinceReferenceDate)
        sqlite3_bind_int(statement, 3, Int32(maximumSafariRows))
        var rows = HistorySnapshot.empty
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let rawURL = sqlite3_column_text(statement, 0), let rawTitle = sqlite3_column_text(statement, 1) {
                let url = String(cString: rawURL)
                let title = String(cString: rawTitle)
                let time = sqlite3_column_double(statement, 2)
                if time.isFinite, let normalized = HistoryIdentity.url(url) {
                    let date = Date(timeIntervalSinceReferenceDate: time)
                    rows.visits.append(HistoryVisit(url: normalized, title: title, lastVisited: date, visitCount: 1))
                    if let query = HistorySearchQuery.from(url: url) {
                        rows.searches.append(PastSearch(query: query, lastUsed: date, useCount: 1))
                    }
                }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw sqliteError(status, database: database)
        }
        return merge(rows, .empty, now: now, additive: true)
    }

    private static func sqliteError(_ code: Int32, database: OpaquePointer?) -> HistoryError {
        switch code & 0xff {
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY: return .needsPermission
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT: return .unavailable
        case SQLITE_IOERR:
            let systemError = database.map(sqlite3_system_errno) ?? 0
            return systemError == EACCES || systemError == EPERM ? .needsPermission : .invalidDatabase
        default: return .invalidDatabase
        }
    }
}

import Foundation

/// Everything Tab Scout learns from how it is used. It stays on this Mac, and Clear Tab Scout History removes it.
struct LearningState: Codable, Equatable {
    var affinity = QueryAffinity()
    var engagement = Engagement()
    var habits = Habits()

    init() {}

    // Each part decodes on its own, so a file written before a part existed still loads.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        affinity = try values.decodeIfPresent(QueryAffinity.self, forKey: .affinity) ?? QueryAffinity()
        engagement = try values.decodeIfPresent(Engagement.self, forKey: .engagement) ?? Engagement()
        habits = try values.decodeIfPresent(Habits.self, forKey: .habits) ?? Habits()
    }
}

// Main-thread owned. Changes are saved together a moment later, on a serial queue.
final class LearningStore {
    private struct Persisted: Codable {
        let version: Int
        let state: LearningState
    }

    static let maximumFileSize = 4 * 1_024 * 1_024
    private let directory: URL?
    private let saveDelay: TimeInterval
    private let queue = DispatchQueue(label: "local.tabscout.learning", qos: .utility)
    private var saveScheduled = false
    private var generation = 0
    private(set) var state: LearningState
    private(set) var storageError = false

    /// A nil directory keeps everything in memory, for previews.
    init(directory: URL?, saveDelay: TimeInterval = 2) {
        self.directory = directory
        self.saveDelay = saveDelay
        state = LearningState()
        guard let file else { return }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumFileSize else { throw HistoryError.storage }
            let persisted = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: file))
            guard persisted.version == 1 else { throw HistoryError.storage }
            state = persisted.state
        } catch {
            // An unreadable file must not stop learning; the next save replaces it.
            storageError = true
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabScout/History", isDirectory: true)
    }

    private var file: URL? { directory?.appendingPathComponent("learning-v1.json") }

    func update(_ change: (inout LearningState) -> Void) {
        precondition(Thread.isMainThread)
        change(&state)
        guard directory != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { [weak self] in self?.save() }
    }

    func clear() {
        precondition(Thread.isMainThread)
        state = LearningState()
        saveScheduled = false
        generation += 1
        guard let file else { return }
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Finishes pending saves and removals before returning, for quitting.
    func flush() {
        if saveScheduled { save() }
        queue.sync {}
    }

    private func save() {
        guard saveScheduled, let directory, let file else { return }
        saveScheduled = false
        let snapshot = state
        let ticket = generation
        queue.async { [weak self] in
            let written = (try? Self.write(snapshot, to: file, in: directory)) != nil
            DispatchQueue.main.async {
                guard let self, ticket == self.generation else { return }
                self.storageError = !written
            }
        }
    }

    private static func write(_ state: LearningState, to file: URL, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Persisted(version: 1, state: state))
        guard data.count <= maximumFileSize else { throw HistoryError.storage }
        // The staging file is private from creation; replacement never exposes it to other users.
        let temporary = directory.appendingPathComponent(".learning-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { throw HistoryError.storage }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if rename(temporary.path, file.path) != 0 { throw HistoryError.storage }
    }
}

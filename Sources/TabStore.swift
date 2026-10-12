import Foundation

struct TabSnapshot {
    let tabs: [SafariTab]
    let active: SafariTab?
    let index: TabSearchIndex
    let fetchedAt: Date
    let revision: Int
}

// Main-thread owned. A stale snapshot can be displayed while one shared refresh runs.
final class TabStore {
    typealias Loader = (@escaping (Result<TabInventory, Error>) -> Void) -> Void
    private let loader: Loader
    private let now: () -> Date
    private let freshFor: TimeInterval
    private let retainFor: TimeInterval
    private var cached: TabSnapshot?
    private var generation = 0
    private var revision = 0
    private var waiters: [(Result<TabSnapshot, Error>) -> Void] = []
    private(set) var isRefreshing = false
    var onPermissionDenied: (() -> Void)?
    /// Called once per accepted Safari read, including background prewarms.
    var onSnapshot: ((TabSnapshot) -> Void)?

    init(freshFor: TimeInterval = 5, retainFor: TimeInterval = 120,
         now: @escaping () -> Date = Date.init, loader: @escaping Loader) {
        self.freshFor = freshFor
        self.retainFor = retainFor
        self.now = now
        self.loader = loader
    }

    var snapshot: TabSnapshot? {
        guard let cached else { return nil }
        let age = now().timeIntervalSince(cached.fetchedAt)
        guard age >= 0, age < retainFor else { self.cached = nil; return nil }
        return cached
    }

    func load(force: Bool = false, completion: @escaping (Result<TabSnapshot, Error>) -> Void) {
        if let snapshot {
            completion(.success(snapshot))
            if !force && now().timeIntervalSince(snapshot.fetchedAt) < freshFor { return }
        }
        waiters.append(completion)
        refresh()
    }

    func prewarm() {
        if let snapshot, now().timeIntervalSince(snapshot.fetchedAt) < freshFor { return }
        refresh()
    }

    /// Records a change Tab Scout made itself. Reads already in flight may predate it and are discarded,
    /// but the cached tabs stay usable with the new on-screen tab (nil when unknown, such as a new tab),
    /// so reopening right away needs no Safari read. The next prewarm still refreshes them.
    func noteActivation(_ active: SafariTab?) {
        guard let snapshot else { return invalidate() }
        generation += 1
        waiters.removeAll()
        isRefreshing = false
        revision += 1
        cached = TabSnapshot(tabs: snapshot.tabs, active: active, index: snapshot.index,
                             fetchedAt: min(snapshot.fetchedAt, now().addingTimeInterval(-freshFor)), revision: revision)
    }

    func invalidate() {
        generation += 1
        cached = nil
        waiters.removeAll()
        isRefreshing = false
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let ticket = generation
        loader { [weak self] result in
            guard let self, ticket == self.generation else { return }
            self.isRefreshing = false
            let response = result.map { inventory in
                self.revision += 1
                let snapshot = TabSnapshot(tabs: inventory.tabs, active: inventory.active, index: TabSearchIndex(inventory.tabs),
                                           fetchedAt: self.now(), revision: self.revision)
                self.cached = snapshot
                return snapshot
            }
            if case .success(let snapshot) = response { self.onSnapshot?(snapshot) }
            if case .failure(BridgeError.permission) = response {
                self.cached = nil
                self.onPermissionDenied?()
            }
            let callbacks = self.waiters
            self.waiters.removeAll()
            callbacks.forEach { $0(response) }
        }
    }
}

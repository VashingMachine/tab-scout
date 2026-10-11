import Foundation

struct TabSnapshot {
    let tabs: [SafariTab]
    let index: TabSearchIndex
    let fetchedAt: Date
    let revision: Int
}

// Main-thread owned. A stale snapshot can be displayed while one shared refresh runs.
final class TabStore {
    typealias Loader = (@escaping (Result<[SafariTab], Error>) -> Void) -> Void
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
            let response = result.map { tabs in
                self.revision += 1
                let snapshot = TabSnapshot(tabs: tabs, index: TabSearchIndex(tabs), fetchedAt: self.now(), revision: self.revision)
                self.cached = snapshot
                return snapshot
            }
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

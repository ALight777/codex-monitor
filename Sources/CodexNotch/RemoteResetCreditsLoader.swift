import Foundation

final class RemoteResetCreditsCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let panelIdentity: String
        let authIndex: String
    }

    struct Revision: Equatable, Sendable {
        let panelIdentity: String
        let value: UInt64
    }

    private struct Entry {
        let value: RateLimitResetCredits
        let storedAt: Date
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var revisionsByPanel: [String: UInt64] = [:]

    init(
        ttl: TimeInterval = 3_600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = max(0, ttl)
        self.now = now
    }

    func beginRevision(panelURL: String) -> Revision {
        let panelIdentity = Self.normalizedPanelIdentity(panelURL)
        lock.lock()
        let nextValue = revisionsByPanel[panelIdentity, default: 0] + 1
        revisionsByPanel[panelIdentity] = nextValue
        lock.unlock()
        return Revision(panelIdentity: panelIdentity, value: nextValue)
    }

    @discardableResult
    func invalidate(_ revision: Revision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revisionsByPanel[revision.panelIdentity] == revision.value else {
            return false
        }
        revisionsByPanel[revision.panelIdentity] = revision.value + 1
        return true
    }

    func fresh(panelURL: String, authIndex: String) -> RateLimitResetCredits? {
        let key = Self.key(panelURL: panelURL, authIndex: authIndex)
        let currentDate = now()
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key],
              currentDate.timeIntervalSince(entry.storedAt) >= 0,
              currentDate.timeIntervalSince(entry.storedAt) < ttl else {
            return nil
        }
        return entry.value
    }

    func stale(panelURL: String, authIndex: String) -> RateLimitResetCredits? {
        let key = Self.key(panelURL: panelURL, authIndex: authIndex)
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.value
    }

    @discardableResult
    func store(
        _ value: RateLimitResetCredits,
        panelURL: String,
        authIndex: String,
        revision: Revision
    ) -> Bool {
        let key = Self.key(panelURL: panelURL, authIndex: authIndex)
        let entry = Entry(value: value, storedAt: now())
        lock.lock()
        defer { lock.unlock() }
        guard revision.panelIdentity == key.panelIdentity,
              revisionsByPanel[key.panelIdentity] == revision.value else {
            return false
        }
        entries[key] = entry
        return true
    }

    static func key(panelURL: String, authIndex: String) -> Key {
        Key(
            panelIdentity: normalizedPanelIdentity(panelURL),
            authIndex: authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func normalizedPanelIdentity(_ panelURL: String) -> String {
        if let managementURL = CLIProxyAPIClient.managementBaseURL(from: panelURL),
           var components = URLComponents(url: managementURL, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if (components.scheme == "https" && components.port == 443)
                || (components.scheme == "http" && components.port == 80) {
                components.port = nil
            }
            components.query = nil
            components.fragment = nil
            return components.string ?? managementURL.absoluteString
        }
        return panelURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct RemoteResetCreditsCandidate: Sendable {
    let accountIndex: Int
    let authIndex: String
    let accountID: String?
}

private struct RemoteResetCreditsOutcome: Sendable {
    let candidate: RemoteResetCreditsCandidate
    let credits: RateLimitResetCredits?
    let succeeded: Bool
}

private struct RemoteResetCreditsWorkerResult: Sendable {
    let outcomes: [RemoteResetCreditsOutcome]
    let cancelled: Bool
}

private actor RemoteResetCreditsCandidateQueue {
    private let candidates: [RemoteResetCreditsCandidate]
    private var nextIndex = 0
    private var cancelled = false

    init(candidates: [RemoteResetCreditsCandidate]) {
        self.candidates = candidates
    }

    func next() -> RemoteResetCreditsCandidate? {
        guard !cancelled, nextIndex < candidates.count else {
            return nil
        }
        defer { nextIndex += 1 }
        return candidates[nextIndex]
    }

    func cancel() {
        cancelled = true
    }
}

struct RemoteResetCreditsLoader: Sendable {
    typealias Fetch = @Sendable (_ authIndex: String, _ accountID: String?) async throws -> RateLimitResetCredits?

    let cache: RemoteResetCreditsCache
    let maxConcurrentRequests: Int

    init(cache: RemoteResetCreditsCache, maxConcurrentRequests: Int = 2) {
        self.cache = cache
        self.maxConcurrentRequests = max(1, min(2, maxConcurrentRequests))
    }

    func load(
        accounts: [RemoteCodexAccount],
        dataSource: RemoteCodexDataSource,
        panelURL: String,
        forceRefresh: Bool = false,
        revision suppliedRevision: RemoteResetCreditsCache.Revision? = nil,
        fetch: @escaping Fetch
    ) async -> [RemoteCodexAccount] {
        guard dataSource == .cpaManagerPlus, !accounts.isEmpty else {
            return accounts
        }

        let eligible = accounts.enumerated().compactMap { index, account -> RemoteResetCreditsCandidate? in
            guard let rawAuthIndex = account.authIndex else {
                return nil
            }
            let authIndex = rawAuthIndex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authIndex.isEmpty else {
                return nil
            }
            return RemoteResetCreditsCandidate(
                accountIndex: index,
                authIndex: authIndex,
                accountID: account.chatgptAccountID
            )
        }
        guard !eligible.isEmpty else {
            return accounts
        }

        let revision = suppliedRevision ?? cache.beginRevision(panelURL: panelURL)
        var result = accounts
        var pending: [RemoteResetCreditsCandidate] = []
        for candidate in eligible {
            if !forceRefresh,
               let cached = cache.fresh(panelURL: panelURL, authIndex: candidate.authIndex) {
                result[candidate.accountIndex] = result[candidate.accountIndex].withResetCredits(cached)
            } else {
                pending.append(candidate)
            }
        }
        guard !pending.isEmpty else {
            return result
        }

        let queue = RemoteResetCreditsCandidateQueue(candidates: pending)
        let workerCount = min(maxConcurrentRequests, pending.count)
        let workerResults = await withTaskGroup(
            of: RemoteResetCreditsWorkerResult.self,
            returning: (outcomes: [RemoteResetCreditsOutcome], cancelled: Bool).self
        ) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var outcomes: [RemoteResetCreditsOutcome] = []
                    while !Task.isCancelled, let candidate = await queue.next() {
                        do {
                            let credits = try await fetch(candidate.authIndex, candidate.accountID)
                            if Task.isCancelled {
                                cache.invalidate(revision)
                                await queue.cancel()
                                return RemoteResetCreditsWorkerResult(outcomes: outcomes, cancelled: true)
                            }
                            let resolvedCredits: RateLimitResetCredits?
                            if let fetched = credits {
                                let stored = cache.store(
                                    fetched,
                                    panelURL: panelURL,
                                    authIndex: candidate.authIndex,
                                    revision: revision
                                )
                                resolvedCredits = stored
                                    ? fetched
                                    : cache.stale(panelURL: panelURL, authIndex: candidate.authIndex)
                            } else {
                                resolvedCredits = cache.stale(
                                    panelURL: panelURL,
                                    authIndex: candidate.authIndex
                                )
                            }
                            outcomes.append(
                                RemoteResetCreditsOutcome(
                                    candidate: candidate,
                                    credits: resolvedCredits,
                                    succeeded: true
                                )
                            )
                        } catch is CancellationError {
                            cache.invalidate(revision)
                            await queue.cancel()
                            return RemoteResetCreditsWorkerResult(outcomes: outcomes, cancelled: true)
                        } catch {
                            outcomes.append(
                                RemoteResetCreditsOutcome(
                                    candidate: candidate,
                                    credits: cache.stale(
                                        panelURL: panelURL,
                                        authIndex: candidate.authIndex
                                    ),
                                    succeeded: false
                                )
                            )
                        }
                    }
                    let cancelled = Task.isCancelled
                    if cancelled {
                        cache.invalidate(revision)
                    }
                    return RemoteResetCreditsWorkerResult(outcomes: outcomes, cancelled: cancelled)
                }
            }

            var outcomes: [RemoteResetCreditsOutcome] = []
            var wasCancelled = false
            while let workerResult = await group.next() {
                outcomes.append(contentsOf: workerResult.outcomes)
                if workerResult.cancelled {
                    wasCancelled = true
                    await queue.cancel()
                    group.cancelAll()
                }
            }
            return (outcomes, wasCancelled || Task.isCancelled)
        }

        for outcome in workerResults.outcomes {
            if let credits = outcome.credits {
                result[outcome.candidate.accountIndex] = result[outcome.candidate.accountIndex]
                    .withResetCredits(credits)
            }
        }

        return result
    }

    func mergingCachedCredits(
        into accounts: [RemoteCodexAccount],
        panelURL: String
    ) -> [RemoteCodexAccount] {
        accounts.map { account in
            guard let rawAuthIndex = account.authIndex else {
                return account
            }
            let authIndex = rawAuthIndex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authIndex.isEmpty,
                  let cached = cache.stale(panelURL: panelURL, authIndex: authIndex) else {
                return account
            }
            return account.withResetCredits(cached)
        }
    }
}

private final class RemoteResetCreditsRaceGate: @unchecked Sendable {
    enum Completion: Sendable {
        case enriched([RemoteCodexAccount])
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var resolved = false
    private let continuation: AsyncStream<Completion>.Continuation

    init(continuation: AsyncStream<Completion>.Continuation) {
        self.continuation = continuation
    }

    func resolve(
        _ completion: Completion,
        beforePublish: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        beforePublish?()
        continuation.yield(completion)
        continuation.finish()
    }
}

struct RemoteResetCreditsEnrichmentCoordinator: Sendable {
    static let minimumTimeout: TimeInterval = 5
    static let maximumTimeout: TimeInterval = 20
    static let requestTimeoutMultiplier: Double = 2

    let loader: RemoteResetCreditsLoader
    let timeoutBudget: TimeInterval

    init(loader: RemoteResetCreditsLoader, timeoutBudget: TimeInterval) {
        self.loader = loader
        self.timeoutBudget = min(Self.maximumTimeout, max(0.01, timeoutBudget))
    }

    static func timeoutBudget(forRequestTimeout requestTimeout: TimeInterval) -> TimeInterval {
        // Allow two request windows while keeping optional enrichment bounded.
        min(
            maximumTimeout,
            max(minimumTimeout, requestTimeout * requestTimeoutMultiplier)
        )
    }

    func enrich(
        accounts: [RemoteCodexAccount],
        dataSource: RemoteCodexDataSource,
        panelURL: String,
        forceRefresh: Bool = false,
        fetch: @escaping RemoteResetCreditsLoader.Fetch
    ) async -> [RemoteCodexAccount] {
        guard dataSource == .cpaManagerPlus, !accounts.isEmpty else {
            return accounts
        }

        let revision = loader.cache.beginRevision(panelURL: panelURL)
        let pair = AsyncStream<RemoteResetCreditsRaceGate.Completion>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let gate = RemoteResetCreditsRaceGate(continuation: pair.continuation)
        let loaderTask = Task.detached(priority: .utility) {
            gate.resolve(
                .enriched(
                    await loader.load(
                        accounts: accounts,
                        dataSource: dataSource,
                        panelURL: panelURL,
                        forceRefresh: forceRefresh,
                        revision: revision,
                        fetch: fetch
                    )
                )
            )
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutBudget * 1_000_000_000))
                gate.resolve(.timedOut) {
                    loader.cache.invalidate(revision)
                }
            } catch is CancellationError {
                return
            } catch {
                gate.resolve(.timedOut) {
                    loader.cache.invalidate(revision)
                }
            }
        }

        var iterator = pair.stream.makeAsyncIterator()
        let completion = await withTaskCancellationHandler {
            await iterator.next() ?? .cancelled
        } onCancel: {
            gate.resolve(.cancelled) {
                loader.cache.invalidate(revision)
            }
        }
        loaderTask.cancel()
        timeoutTask.cancel()

        switch completion {
        case .enriched(let enriched):
            return enriched
        case .timedOut, .cancelled:
            return loader.mergingCachedCredits(into: accounts, panelURL: panelURL)
        }
    }
}

enum RemoteCoreThenEnrichmentPipeline {
    static func run<Core, Output>(
        core: () async throws -> Core,
        enrichment: (Core) async -> Output
    ) async rethrows -> Output {
        let coreValue = try await core()
        return await enrichment(coreValue)
    }
}

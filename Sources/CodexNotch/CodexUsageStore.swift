import Foundation
import Darwin

private enum UsageScanPolicy {
    static let ripgrepCandidates = [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        "/usr/bin/rg"
    ]
    static let runningActivityWindow = 180
    static let largeSessionTokenScanLimit: UInt64 = 20 * 1024 * 1024
    static let staleSessionTokenScanLimit: UInt64 = 2 * 1024 * 1024
    static let recentSessionScanWindow: TimeInterval = 10 * 60
    static let periodUsageTailLineLimit = 4_000
    static let estimatedTokenLineBytes: UInt64 = 1_300
    static let periodUsageCacheTTL: TimeInterval = 120
    static let ripgrepTimeout: DispatchTimeInterval = .seconds(12)
    static let appServerSuccessCacheTTL: TimeInterval = 30
    static let appServerFailureCacheTTL: TimeInterval = 45
}

final class CodexUsageStore: @unchecked Sendable {
    private struct SessionLineEvent {
        let timestamp: Date
        let topLevelType: String?
        let payloadType: String?
        let payloadPhase: String?
        let payloadStatus: String?
    }

    private let codexDirectory: URL
    private let stateDatabase: String
    private let logsDatabase: String
    private let sessionIndexPath: String
    private let appServerExecutable = "/Applications/Codex.app/Contents/Resources/codex"
    private let ripgrepCandidates: [String]
    private let tokenPattern = /tool_token_count=([0-9]+)/
    private let terminalEventTypes: Set<String> = [
        "task_complete",
        "task_completed",
        "task_stopped",
        "task_failed",
        "task_cancelled",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "turn_failed",
        "turn_cancelled"
    ]
    private let cacheLock = NSLock()
    private var fastCache: FastSnapshotCache?
    private var recentPathsCache: RecentPathsCache?
    private var recentTaskPathsCache: RecentPathsCache?
    private var appServerRateLimitCache: AppServerRateLimitCache?
    private var periodUsageCache: PeriodUsageCache?
    private var sessionTokenTotalCache: [String: SessionTokenTotalCache] = [:]

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        ripgrepCandidates: [String] = UsageScanPolicy.ripgrepCandidates
    ) {
        self.codexDirectory = codexDirectory
        self.ripgrepCandidates = ripgrepCandidates
        self.stateDatabase = Self.latestSQLiteDatabase(
            in: codexDirectory,
            prefix: "state_",
            fallback: "state_5.sqlite"
        )
        self.logsDatabase = Self.latestSQLiteDatabase(
            in: codexDirectory,
            prefix: "logs_",
            fallback: "logs_2.sqlite"
        )
        self.sessionIndexPath = codexDirectory.appendingPathComponent("session_index.jsonl").path
    }

    private static func latestSQLiteDatabase(in directory: URL, prefix: String, fallback: String) -> String {
        let fallbackPath = directory.appendingPathComponent(fallback).path
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return fallbackPath
        }

        let candidates = urls.compactMap { url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else {
                return nil
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else {
                return nil
            }
            let suffix = name.dropFirst(prefix.count)
            guard let version = Int(suffix) else {
                return nil
            }
            return (version, url.path)
        }

        return candidates.max { $0.version < $1.version }?.path ?? fallbackPath
    }

    func loadSnapshot(
        includePeriodUsage: Bool = true,
        fallbackUsage: PeriodUsage? = nil,
        bypassFastCache: Bool = false,
        rateLimitSource: RateLimitSourcePreference = .appServerFirst,
        taskHistoryRange: TaskHistoryRange = .threeDays,
        now: Date = Date()
    ) -> UsageSnapshot {
        if !bypassFastCache,
           !includePeriodUsage,
           let cachedSnapshot = cachedFastSnapshot(
                now: now,
                fallbackUsage: fallbackUsage,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange
           ) {
            return cachedSnapshot
        }

        do {
            let databaseThreads = try loadRecentThreads(range: taskHistoryRange, now: now)
            let knownTokens = tokenMap(from: databaseThreads)
            let sessionThreads = loadRecentSessionThreads(
                range: taskHistoryRange,
                now: now,
                knownTokens: knownTokens
            )
            let activeSubagentParents = loadActiveSubagentParentThreads(now: now)
            let subagentUsage = loadSubagentUsage(range: taskHistoryRange, now: now)
            let threads = withSubagentUsage(
                mergeThreadRecords(databaseThreads + sessionThreads + activeSubagentParents),
                usage: subagentUsage
            )
            let activeThreadIDs = ((try? loadActiveThreadIDs(now: now)) ?? [])
                .union(activeSessionThreadIDs(from: sessionThreads, now: now))
                .union(activeSubagentParents.map(\.id))
            let usage = includePeriodUsage
                ? (loadUsageTotals(now: now, fallbackThreads: threads) ?? fallbackUsage ?? .zero)
                : (fallbackUsage ?? .zero)
            let rateLimitPaths = candidateRateLimitPaths(from: threads)
            let rateLimits = loadRateLimits(from: rateLimitPaths, source: rateLimitSource, now: now)
            let tasks = buildTasks(from: threads, activeThreadIDs: activeThreadIDs, now: now)
            cacheFastSnapshot(
                threads: threads,
                activeThreadIDs: activeThreadIDs,
                rateLimits: rateLimits,
                signaturePaths: rateLimitPaths,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange
            )

            return UsageSnapshot(
                primaryPercent: rateLimits.primaryDisplayPercent(now: now),
                secondaryPercent: rateLimits.secondaryDisplayPercent(now: now),
                usage24h: usage.day,
                usage7d: usage.week,
                usage30d: usage.month,
                tasks: tasks,
                isRunning: tasks.contains { $0.status == .running },
                lastUpdated: now,
                errorMessage: nil
            )
        } catch {
            return errorSnapshot(error, now: now)
        }
    }

    func loadUsageTotals(now: Date = Date()) -> PeriodUsage? {
        let periodThreads = (try? loadThreadsForPeriodUsage(now: now)) ?? []
        let sessionThreads = loadSessionUsageThreads(
            range: .month,
            now: now,
            knownTokens: tokenMap(from: periodThreads)
        )
        let usageThreads = mergeThreadRecords(periodThreads + sessionThreads)
        guard !usageThreads.isEmpty,
              let usage = try? loadPeriodUsage(now: now, threads: usageThreads) else {
            return nil
        }
        return usage
    }

    func rateLimitWatchPaths() -> [String] {
        let threads = (try? loadRecentThreads()) ?? []
        return uniqueExistingPaths(
            candidateRateLimitPaths(from: threads, recentLimit: 10)
                + recentSessionActivityWatchPaths()
        )
    }

    private func errorSnapshot(_ error: Error, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primaryPercent: nil,
            secondaryPercent: nil,
            usage24h: 0,
            usage7d: 0,
            usage30d: 0,
            tasks: [],
            isRunning: false,
            lastUpdated: now,
            errorMessage: error.localizedDescription
        )
    }

    private func loadUsageTotals(now: Date, fallbackThreads: [ThreadRecord]?) -> PeriodUsage? {
        let periodThreads = (try? loadThreadsForPeriodUsage(now: now)) ?? []
        let knownTokens = tokenMap(from: periodThreads + (fallbackThreads ?? []))
        let sessionThreads = loadSessionUsageThreads(
            range: .month,
            now: now,
            knownTokens: knownTokens
        )
        let usageThreads = mergeThreadRecords(periodThreads + sessionThreads + (fallbackThreads ?? []))
        guard !usageThreads.isEmpty else {
            return nil
        }
        return try? loadPeriodUsage(now: now, threads: usageThreads)
    }

    private func cachedFastSnapshot(
        now: Date,
        fallbackUsage: PeriodUsage?,
        rateLimitSource: RateLimitSourcePreference,
        taskHistoryRange: TaskHistoryRange
    ) -> UsageSnapshot? {
        cacheLock.lock()
        let cache = fastCache
        cacheLock.unlock()

        guard let cache,
              cache.rateLimitSource == rateLimitSource,
              cache.taskHistoryRange == taskHistoryRange,
              now.timeIntervalSince(cache.createdAt) < 1.5,
              makeSignature(for: cache.rolloutPaths) == cache.signature else {
            return nil
        }

        let usage = fallbackUsage ?? .zero
        let tasks = buildTasks(from: cache.threads, activeThreadIDs: cache.activeThreadIDs, now: now)
        return UsageSnapshot(
            primaryPercent: cache.rateLimits.primaryDisplayPercent(now: now),
            secondaryPercent: cache.rateLimits.secondaryDisplayPercent(now: now),
            usage24h: usage.day,
            usage7d: usage.week,
            usage30d: usage.month,
            tasks: tasks,
            isRunning: tasks.contains { $0.status == .running },
            lastUpdated: now,
            errorMessage: nil
        )
    }

    private func cacheFastSnapshot(
        threads: [ThreadRecord],
        activeThreadIDs: Set<String>,
        rateLimits: RateLimitSnapshot,
        signaturePaths: [String],
        rateLimitSource: RateLimitSourcePreference,
        taskHistoryRange: TaskHistoryRange
    ) {
        let rolloutPaths = Array(Set(signaturePaths + threads.map(\.rolloutPath)).filter { !$0.isEmpty }).sorted()
        guard let signature = makeSignature(for: rolloutPaths) else {
            return
        }

        cacheLock.lock()
        fastCache = FastSnapshotCache(
            createdAt: Date(),
            signature: signature,
            rolloutPaths: rolloutPaths,
            threads: threads,
            activeThreadIDs: activeThreadIDs,
            rateLimits: rateLimits,
            rateLimitSource: rateLimitSource,
            taskHistoryRange: taskHistoryRange
        )
        cacheLock.unlock()
    }

    private func loadRecentThreads(range: TaskHistoryRange = .threeDays, now: Date = Date()) throws -> [ThreadRecord] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let query = """
        select
          id,
          coalesce(title, '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          model,
          reasoning_effort,
          coalesce(rollout_path, '') as rollout_path,
          coalesce(updated_at, 0) as updated_at
        from threads
        where archived = 0
          and updated_at >= \(since)
        order by updated_at desc
        limit \(range.queryLimit);
        """
        return withSessionIndexNames(
            try Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadRecord].self)
        )
        .filter { !isSubagentThread($0) }
    }

    private func loadRecentSessionThreads(
        range: TaskHistoryRange,
        now: Date,
        includeSubagents: Bool = false,
        knownTokens: [String: Int] = [:]
    ) -> [ThreadRecord] {
        let names = loadSessionIndexThreadNames()
        return loadRecentSessionCandidates(
            range: range,
            now: now,
            knownTokens: knownTokens
        ).compactMap { candidate in
            let meta = sessionMeta(from: candidate.path)
            guard includeSubagents || meta?.isSubagent != true else {
                return nil
            }

            let runtime = sessionRuntimeInfo(from: candidate.path)
            let title = names[candidate.sessionID] ?? sessionTitle(from: candidate.path) ?? "未命名任务"
            let tokensUsed = tokenTotalForFastSnapshot(
                path: candidate.path,
                databaseTokens: candidate.databaseTokens
            )
            return ThreadRecord(
                id: candidate.sessionID,
                title: title,
                tokensUsed: tokensUsed,
                model: runtime?.model,
                reasoningEffort: runtime?.reasoningEffort,
                rolloutPath: candidate.path,
                updatedAt: candidate.updatedAt
            )
        }
    }

    private func loadSessionUsageThreads(
        range: TaskHistoryRange,
        now: Date,
        knownTokens: [String: Int] = [:]
    ) -> [ThreadRecord] {
        loadRecentSessionCandidates(
            range: range,
            now: now,
            knownTokens: knownTokens
        ).compactMap { candidate in
            let tokensUsed = tokenTotalForPeriodUsage(
                path: candidate.path,
                databaseTokens: candidate.databaseTokens,
                modifiedAt: candidate.modifiedAt,
                now: now
            )
            guard tokensUsed > 0 else {
                return nil
            }

            return ThreadRecord(
                id: candidate.sessionID,
                title: "",
                tokensUsed: tokensUsed,
                model: nil,
                reasoningEffort: nil,
                rolloutPath: candidate.path,
                updatedAt: candidate.updatedAt
            )
        }
    }

    private func loadRecentSessionCandidates(
        range: TaskHistoryRange,
        now: Date,
        knownTokens: [String: Int]
    ) -> [RecentSessionCandidate] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let paths = recentTaskSessionPaths(limit: max(range.queryLimit * 3, 80))
        let pathSessionIDs = paths.compactMap { sessionID(from: $0)?.lowercased() }
        var resolvedKnownTokens = knownTokens
        let missingTokenIDs = pathSessionIDs.filter { resolvedKnownTokens[$0] == nil }
        if !missingTokenIDs.isEmpty {
            resolvedKnownTokens.merge(loadThreadTokenMap(for: missingTokenIDs), uniquingKeysWith: max)
        }

        return paths.compactMap { path in
            guard let sessionID = sessionID(from: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                return nil
            }

            let updatedAt = Int(modifiedAt.timeIntervalSince1970)
            guard updatedAt >= since else {
                return nil
            }

            return RecentSessionCandidate(
                path: path,
                sessionID: sessionID,
                modifiedAt: modifiedAt,
                updatedAt: updatedAt,
                databaseTokens: resolvedKnownTokens[sessionID.lowercased()] ?? 0
            )
        }
    }

    private func activeSessionThreadIDs(from threads: [ThreadRecord], now: Date) -> Set<String> {
        return Set(threads.compactMap { thread in
            sessionLooksActive(path: thread.rolloutPath, fallbackUpdatedAt: thread.updatedAt, now: now) ? thread.id : nil
        })
    }

    private func isSubagentThread(_ thread: ThreadRecord) -> Bool {
        guard !thread.rolloutPath.isEmpty,
              let meta = sessionMeta(from: thread.rolloutPath) else {
            return false
        }
        return meta.isSubagent
    }

    private func loadActiveSubagentParentThreads(now: Date) -> [ThreadRecord] {
        let paths = recentTaskSessionPaths(limit: 48)
        let names = loadSessionIndexThreadNames()

        let parents = paths.compactMap { path -> ThreadRecord? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let meta = sessionMeta(from: path),
                  meta.isSubagent,
                  let parentThreadID = meta.parentThreadID,
                  !parentThreadID.isEmpty,
                  sessionLooksActive(path: path, fallbackUpdatedAt: Int(modifiedAt.timeIntervalSince1970), now: now) else {
                return nil
            }
            let parentPath = sessionPath(for: parentThreadID)
            let runtime = parentPath.flatMap(sessionRuntimeInfo(from:))
            let title = parentPath.flatMap { names[parentThreadID] ?? sessionTitle(from: $0) }
                ?? names[parentThreadID]
                ?? "正在运行的 Codex 任务"
            let parentUpdatedAt = parentPath.flatMap { path -> Int? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return Int(modifiedAt.timeIntervalSince1970)
            } ?? 0
            let updatedAt = max(parentUpdatedAt, Int(modifiedAt.timeIntervalSince1970))
            return ThreadRecord(
                id: parentThreadID,
                title: title,
                tokensUsed: parentPath.flatMap(sessionTokenTotal(from:)) ?? 0,
                model: runtime?.model,
                reasoningEffort: runtime?.reasoningEffort,
                rolloutPath: parentPath ?? "",
                updatedAt: updatedAt
            )
        }

        return mergeThreadRecords(parents)
    }

    private func loadSubagentUsage(range: TaskHistoryRange, now: Date) -> [String: (count: Int, tokens: Int)] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let paths = recentTaskSessionPaths(limit: max(range.queryLimit * 3, 80))
        let sessionIDsByPath = Dictionary(
            uniqueKeysWithValues: paths.compactMap { path -> (String, String)? in
                guard let id = sessionID(from: path)?.lowercased() else {
                    return nil
                }
                return (path, id)
            }
        )
        let knownTokens = loadThreadTokenMap(for: Array(sessionIDsByPath.values))
        var usage: [String: (count: Int, tokens: Int)] = [:]

        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let sessionID = sessionIDsByPath[path],
                  Int(modifiedAt.timeIntervalSince1970) >= since,
                  let meta = sessionMeta(from: path),
                  meta.isSubagent,
                  let parentThreadID = meta.parentThreadID,
                  !parentThreadID.isEmpty else {
                continue
            }

            let key = parentThreadID.lowercased()
            let current = usage[key] ?? (count: 0, tokens: 0)
            let isActive = sessionLooksActive(
                path: path,
                fallbackUpdatedAt: Int(modifiedAt.timeIntervalSince1970),
                now: now
            )
            let knownTokenTotal = knownTokens[sessionID] ?? 0
            let tokenTotal = tokenTotalForFastSnapshot(path: path, databaseTokens: knownTokenTotal, allowInactiveScan: false)
            usage[key] = (
                count: current.count + (isActive ? 1 : 0),
                tokens: current.tokens + tokenTotal
            )
        }

        return usage
    }

    private func withSubagentUsage(
        _ threads: [ThreadRecord],
        usage: [String: (count: Int, tokens: Int)]
    ) -> [ThreadRecord] {
        guard !usage.isEmpty else {
            return threads
        }

        return threads.map { thread in
            guard let summary = usage[thread.id.lowercased()] else {
                return thread
            }
            let count = summary.count
            let parentTokens = parentTokenCount(for: thread)
            let tokensUsed = max(thread.tokensUsed, parentTokens + summary.tokens)

            return ThreadRecord(
                id: thread.id,
                title: thread.title,
                tokensUsed: tokensUsed,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort,
                rolloutPath: thread.rolloutPath,
                updatedAt: thread.updatedAt,
                activeSubagentCount: count
            )
        }
    }

    private func parentTokenCount(for thread: ThreadRecord) -> Int {
        guard !thread.rolloutPath.isEmpty else {
            return thread.tokensUsed
        }
        return tokenTotalForFastSnapshot(path: thread.rolloutPath, databaseTokens: thread.tokensUsed)
    }

    private func tokenTotalForFastSnapshot(
        path: String,
        databaseTokens: Int,
        allowInactiveScan: Bool = true
    ) -> Int {
        guard !path.isEmpty else {
            return databaseTokens
        }

        let signature = fileSignature(path)
        guard signature.exists else {
            return databaseTokens
        }

        guard allowInactiveScan || databaseTokens <= 0 else {
            return databaseTokens
        }

        if databaseTokens > 0, signature.size > UsageScanPolicy.largeSessionTokenScanLimit {
            return databaseTokens
        }

        return max(databaseTokens, sessionTokenTotal(from: path) ?? 0)
    }

    private func tokenTotalForPeriodUsage(
        path: String,
        databaseTokens: Int,
        modifiedAt: Date,
        now: Date
    ) -> Int {
        guard !path.isEmpty else {
            return databaseTokens
        }

        let signature = fileSignature(path)
        guard signature.exists else {
            return databaseTokens
        }

        if databaseTokens > 0, signature.size > UsageScanPolicy.largeSessionTokenScanLimit {
            return databaseTokens
        }

        let changedRecently = now.timeIntervalSince(modifiedAt) < UsageScanPolicy.recentSessionScanWindow
        if changedRecently {
            return max(databaseTokens, sessionTokenTotal(from: path) ?? 0)
        }

        if databaseTokens > 0 {
            return databaseTokens
        }

        guard signature.size <= UsageScanPolicy.staleSessionTokenScanLimit else {
            return 0
        }

        return sessionTokenTotal(from: path) ?? 0
    }

    private func tokenMap(from threads: [ThreadRecord]) -> [String: Int] {
        Dictionary(
            threads.map { ($0.id.lowercased(), $0.tokensUsed) },
            uniquingKeysWith: max
        )
    }

    private func loadThreadTokenMap(for ids: [String]) -> [String: Int] {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else {
            return [:]
        }

        let quotedIDs = uniqueIDs
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        let query = """
        select id, coalesce(tokens_used, 0) as tokens_used
        from threads
        where id in (\(quotedIDs));
        """

        guard let records = try? Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadTokenRecord].self) else {
            return [:]
        }

        return Dictionary(
            records.map { ($0.id.lowercased(), $0.tokensUsed) },
            uniquingKeysWith: max
        )
    }

    private func mergeThreadRecords(_ records: [ThreadRecord]) -> [ThreadRecord] {
        var merged: [String: ThreadRecord] = [:]

        for record in records {
            guard !record.id.isEmpty else {
                continue
            }

            if let existing = merged[record.id] {
                merged[record.id] = mergeThreadRecord(existing, with: record)
            } else {
                merged[record.id] = record
            }
        }

        return merged.values.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.title < $1.title
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func mergeThreadRecord(_ existing: ThreadRecord, with candidate: ThreadRecord) -> ThreadRecord {
        let updatedAt = max(existing.updatedAt, candidate.updatedAt)
        let title = bestTitle(existing.title, candidate.title)
        let tokensUsed = max(existing.tokensUsed, candidate.tokensUsed)
        let rolloutPath = candidate.rolloutPath.isEmpty ? existing.rolloutPath : candidate.rolloutPath

        return ThreadRecord(
            id: existing.id,
            title: title,
            tokensUsed: tokensUsed,
            model: existing.model ?? candidate.model,
            reasoningEffort: existing.reasoningEffort ?? candidate.reasoningEffort,
            rolloutPath: rolloutPath,
            updatedAt: updatedAt,
            activeSubagentCount: max(existing.activeSubagentCount, candidate.activeSubagentCount)
        )
    }

    private func bestTitle(_ first: String, _ second: String) -> String {
        let firstTrimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondTrimmed = second.trimmingCharacters(in: .whitespacesAndNewlines)

        if firstTrimmed.isEmpty || firstTrimmed == "未命名任务" {
            return secondTrimmed.isEmpty ? "未命名任务" : secondTrimmed
        }
        return firstTrimmed
    }

    private func loadThreadsForPeriodUsage(now: Date) throws -> [ThreadRecord] {
        let monthStart = Int(now.timeIntervalSince1970) - (30 * 24 * 60 * 60)
        let query = """
        select
          id,
          coalesce(title, '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          model,
          reasoning_effort,
          coalesce(rollout_path, '') as rollout_path,
          coalesce(updated_at, 0) as updated_at
        from threads
        where updated_at >= \(monthStart)
        order by updated_at desc;
        """
        return withSessionIndexNames(
            try Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadRecord].self)
        )
    }

    private func withSessionIndexNames(_ threads: [ThreadRecord]) -> [ThreadRecord] {
        let indexedNames = loadSessionIndexThreadNames()
        guard !indexedNames.isEmpty else {
            return threads
        }

        return threads.map { thread in
            guard let indexedName = indexedNames[thread.id],
                  !indexedName.isEmpty,
                  indexedName != thread.title else {
                return thread
            }

            return ThreadRecord(
                id: thread.id,
                title: indexedName,
                tokensUsed: thread.tokensUsed,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort,
                rolloutPath: thread.rolloutPath,
                updatedAt: thread.updatedAt,
                activeSubagentCount: thread.activeSubagentCount
            )
        }
    }

    private func loadSessionIndexThreadNames() -> [String: String] {
        guard let content = try? String(contentsOfFile: sessionIndexPath, encoding: .utf8) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var names: [String: String] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            guard let record = try? decoder.decode(SessionIndexRecord.self, from: Data(line.utf8)) else {
                continue
            }

            let name = record.threadName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                continue
            }
            names[record.id] = name
        }

        return names
    }

    private func loadPeriodUsage(now: Date, threads: [ThreadRecord]) throws -> PeriodUsage {
        let rolloutPaths = Array(Set(threads.map(\.rolloutPath)).filter { !$0.isEmpty }).sorted()
        let signature = makeUsageSignature(for: rolloutPaths)
        if let signature,
           let cached = cachedPeriodUsage(now: now, signature: signature) {
            return cached
        }

        let rolloutUsage = loadPeriodUsageFromRollouts(now: now, threads: threads)
        let logUsage = (try? loadPeriodUsageFromLogs(now: now)) ?? .zero
        let usage = maxPeriodUsage(rolloutUsage, logUsage)

        if let signature {
            cachePeriodUsage(usage, signature: signature, now: now)
        }

        return usage
    }

    private func maxPeriodUsage(_ lhs: PeriodUsage, _ rhs: PeriodUsage) -> PeriodUsage {
        PeriodUsage(
            day: max(lhs.day, rhs.day),
            week: max(lhs.week, rhs.week),
            month: max(lhs.month, rhs.month)
        )
    }

    private func cachedPeriodUsage(now: Date, signature: StoreSignature) -> PeriodUsage? {
        cacheLock.lock()
        let cache = periodUsageCache
        cacheLock.unlock()

        guard let cache,
              cache.signature == signature,
              now.timeIntervalSince(cache.createdAt) < UsageScanPolicy.periodUsageCacheTTL else {
            return nil
        }
        return cache.usage
    }

    private func cachePeriodUsage(_ usage: PeriodUsage, signature: StoreSignature, now: Date) {
        cacheLock.lock()
        periodUsageCache = PeriodUsageCache(createdAt: now, signature: signature, usage: usage)
        cacheLock.unlock()
    }

    private func loadPeriodUsageFromLogs(now: Date) throws -> PeriodUsage {
        let oldest = Int(now.timeIntervalSince1970) - (30 * 24 * 60 * 60)
        let query = """
        select ts, feedback_log_body
        from logs
        where target = 'codex_otel.trace_safe'
          and feedback_log_body like '%event.kind=response.completed%'
          and feedback_log_body like '%tool_token_count=%'
          and ts >= \(oldest)
        order by ts desc;
        """

        let records = try Shell.sqliteJSON(database: logsDatabase, query: query, as: [UsageLogRecord].self)
        let dayStart = Int(now.timeIntervalSince1970) - (24 * 60 * 60)
        let weekStart = Int(now.timeIntervalSince1970) - (7 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        for record in records {
            guard let tokens = extractTokenCount(from: record.feedbackLogBody) else {
                continue
            }
            month += tokens
            if record.ts >= weekStart {
                week += tokens
            }
            if record.ts >= dayStart {
                day += tokens
            }
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func loadPeriodUsageFromRollouts(now: Date, threads: [ThreadRecord]) -> PeriodUsage {
        let paths = Array(Set(threads.map(\.rolloutPath)).filter {
            !$0.isEmpty && FileManager.default.fileExists(atPath: $0)
        }).sorted()
        if let usage = loadPeriodUsageWithRipgrep(now: now, paths: paths) {
            return usage
        }

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        func add(tokens: Int, date: Date) {
            guard tokens > 0, date >= monthStart else {
                return
            }

            month += tokens
            if date >= weekStart {
                week += tokens
            }
            if date >= dayStart {
                day += tokens
            }
        }

        var recordsByPath: [String: ThreadRecord] = [:]
        for thread in threads where !thread.rolloutPath.isEmpty {
            if let existing = recordsByPath[thread.rolloutPath] {
                recordsByPath[thread.rolloutPath] = mergeThreadRecord(existing, with: thread)
            } else {
                recordsByPath[thread.rolloutPath] = thread
            }
        }

        for thread in recordsByPath.values {
            if thread.tokensUsed > 0 {
                add(
                    tokens: thread.tokensUsed,
                    date: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
                )
                continue
            }
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func loadPeriodUsageWithRipgrep(now: Date, paths: [String]) -> PeriodUsage? {
        guard let executable = ripgrepExecutable(),
              !paths.isEmpty else {
            return nil
        }

        guard let output = runRipgrepTokenSearch(executable: executable, paths: paths) else {
            return nil
        }

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let jsonStart = rawLine.firstIndex(of: "{") else {
                continue
            }

            let line = String(rawLine[jsonStart...])
            guard let event = parseTokenCountEvent(line),
                  event.date >= monthStart else {
                continue
            }

            month += event.tokens
            if event.date >= weekStart {
                week += event.tokens
            }
            if event.date >= dayStart {
                day += event.tokens
            }
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func runRipgrepTokenSearch(executable: String, paths: [String]) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-notch-token-lines-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            """
            rg="$1"
            out="$2"
            bytes="$3"
            shift 3
            {
              for path in "$@"; do
                /usr/bin/tail -c "$bytes" -- "$path"
                printf '\\n'
              done
            } | "$rg" --fixed-strings --no-heading --color never -- '"token_count"' > "$out"
            status=$?
            if [ "$status" -eq 1 ]; then
              exit 0
            fi
            exit "$status"
            """,
            "codex-notch-token-search",
            executable,
            outputURL.path,
            String(UsageScanPolicy.periodUsageTailLineLimit * Int(UsageScanPolicy.estimatedTokenLineBytes))
        ] + paths
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            completed.signal()
        }

        if completed.wait(timeout: .now() + UsageScanPolicy.ripgrepTimeout) == .timedOut {
            Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
            if completed.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                _ = completed.wait(timeout: .now() + .milliseconds(300))
            }
            return nil
        }

        guard let data = try? Data(contentsOf: outputURL) else {
            return nil
        }

        if !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func ripgrepExecutable() -> String? {
        ripgrepCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func loadActiveThreadIDs(now: Date) throws -> Set<String> {
        let since = Int(now.timeIntervalSince1970) - 180
        let query = """
        select
          thread_id,
          max(case
            when feedback_log_body like '%response.output_item.added%'
              or feedback_log_body like '%response.output_text.delta%'
              or feedback_log_body like '%"status":"in_progress"%'
            then ts else 0 end) as latest_activity,
          max(case
            when feedback_log_body like '%response.completed%'
              or feedback_log_body like '%response.output_item.done%'
              or feedback_log_body like '%response.function_call_arguments.done%'
              or feedback_log_body like '%"phase":"final_answer"%'
              or feedback_log_body like '%"phase": "final_answer"%'
              or feedback_log_body like '%"type":"task_complete"%'
              or feedback_log_body like '%"type": "task_complete"%'
              or feedback_log_body like '%"type":"task_completed"%'
              or feedback_log_body like '%"type": "task_completed"%'
              or feedback_log_body like '%"type":"task_stopped"%'
              or feedback_log_body like '%"type": "task_stopped"%'
              or feedback_log_body like '%"type":"task_failed"%'
              or feedback_log_body like '%"type": "task_failed"%'
              or feedback_log_body like '%"type":"task_cancelled"%'
              or feedback_log_body like '%"type": "task_cancelled"%'
            then ts else 0 end) as latest_done
        from logs
        where thread_id is not null
          and ts >= \(since)
        group by thread_id;
        """

        let records = try Shell.sqliteJSON(database: logsDatabase, query: query, as: [ActivityRecord].self)
        let nowEpoch = Int(now.timeIntervalSince1970)

        return Set(records.compactMap { record in
            guard let threadId = record.threadId, !threadId.isEmpty else {
                return nil
            }
            let activity = record.latestActivity ?? 0
            let done = record.latestDone ?? 0
            if activity > done && nowEpoch - activity < 180 {
                return threadId
            }
            if activity > 0 && activity >= done && nowEpoch - activity < 20 {
                return threadId
            }
            return nil
        })
    }

    private func buildTasks(from threads: [ThreadRecord], activeThreadIDs: Set<String>, now: Date) -> [CodexTask] {
        let tasks = threads.map { thread -> CodexTask in
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
            let status: TaskStatus = activeThreadIDs.contains(thread.id) ? .running : .recent
            let model = thread.model ?? "模型未知"
            let effort = localizedEffort(thread.reasoningEffort)
            let detail = "\(model) · \(effort) · \(Formatters.relativeAge(updatedAt, now: now))前"

            return CodexTask(
                id: thread.id,
                title: Formatters.shortTitle(thread.title),
                status: status,
                detail: detail,
                tokenCount: thread.tokensUsed,
                updatedAt: updatedAt,
                activeSubagentCount: thread.activeSubagentCount
            )
        }

        let running = tasks.filter { $0.status == .running }
        if !running.isEmpty {
            return running + tasks.filter { $0.status != .running }
        }
        return tasks
    }

    private func sessionLooksActive(path: String, fallbackUpdatedAt: Int, now: Date) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        let nowEpoch = Int(now.timeIntervalSince1970)
        guard nowEpoch - fallbackUpdatedAt < UsageScanPolicy.runningActivityWindow else {
            return false
        }

        guard let text = fileSuffix(from: path, maxBytes: 256 * 1024) else {
            return nowEpoch - fallbackUpdatedAt < 12
        }

        var latestActivity: Date?
        var latestDone: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineText = String(line)
            guard let event = sessionLineEvent(fromJSONLine: lineText) else {
                continue
            }

            if sessionLineMarksCompletion(event) {
                latestDone = maxDate(latestDone, event.timestamp)
            }

            if sessionLineMarksActivity(event) {
                latestActivity = maxDate(latestActivity, event.timestamp)
            }
        }

        if let latestActivity {
            let done = latestDone ?? .distantPast
            if latestActivity > done,
               now.timeIntervalSince(latestActivity) < TimeInterval(UsageScanPolicy.runningActivityWindow) {
                return true
            }
            if now.timeIntervalSince(latestActivity) < 12,
               latestDone == nil {
                return true
            }
        }

        return false
    }

    private func sessionLineEvent(fromJSONLine line: String) -> SessionLineEvent? {
        guard line.contains(#""timestamp""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["timestamp"] as? String,
              let timestamp = parseTimestamp(value) else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        return SessionLineEvent(
            timestamp: timestamp,
            topLevelType: object["type"] as? String,
            payloadType: payload?["type"] as? String,
            payloadPhase: payload?["phase"] as? String,
            payloadStatus: payload?["status"] as? String
        )
    }

    private func sessionLineMarksCompletion(_ event: SessionLineEvent) -> Bool {
        let phase = event.payloadPhase?.lowercased()
        if phase == "final" || phase == "final_answer" {
            return true
        }

        if event.payloadStatus?.lowercased() == "completed" {
            return true
        }

        guard let payloadType = event.payloadType?.lowercased() else {
            return false
        }

        if terminalEventTypes.contains(payloadType) {
            return true
        }

        return payloadType == "response.completed"
            || payloadType == "response.output_item.done"
            || payloadType == "response.function_call_arguments.done"
    }

    private func sessionLineMarksActivity(_ event: SessionLineEvent) -> Bool {
        if event.topLevelType == "response_item" {
            return true
        }

        let payloadType = event.payloadType?.lowercased()
        if payloadType == "response.output_item.added" || payloadType == "response.output_text.delta" {
            return true
        }

        return event.payloadStatus?.lowercased() == "in_progress"
    }

    private func timestamp(fromJSONLine line: String) -> Date? {
        guard line.contains(#""timestamp""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["timestamp"] as? String else {
            return nil
        }
        return parseTimestamp(value)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else {
            return rhs
        }
        return max(lhs, rhs)
    }

    private func sessionTitle(from path: String) -> String? {
        guard let text = filePrefix(from: path, maxBytes: 256 * 1024) else {
            return nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""role":"user""#) || line.contains(#""role": "user""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else {
                continue
            }

            for item in content {
                guard let text = item["text"] as? String,
                      let title = normalizedSessionTitle(from: text) else {
                    continue
                }
                return title
            }
        }

        return nil
    }

    private func normalizedSessionTitle(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestRange = candidate.range(of: "## My request for Codex:") {
            candidate = String(candidate[requestRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in candidate.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("<environment_context"),
                  !trimmed.hasPrefix("</environment_context"),
                  !trimmed.hasPrefix("<permissions instructions"),
                  !trimmed.hasPrefix("<app-context"),
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("# In app browser"),
                  !trimmed.hasPrefix("## My request for Codex:"),
                  !trimmed.hasPrefix("- ") else {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func sessionID(from path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let pieces = name.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count >= 5 else {
            return nil
        }

        let suffix = pieces.suffix(5).joined(separator: "-")
        let idPieces = suffix.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard idPieces.map(\.count) == [8, 4, 4, 4, 12] else {
            return nil
        }

        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard idPieces.joined().unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            return nil
        }

        return suffix.lowercased()
    }

    private func sessionTokenTotal(from path: String) -> Int? {
        let signature = fileSignature(path)
        guard signature.exists else {
            return nil
        }

        cacheLock.lock()
        if let cached = sessionTokenTotalCache[path],
           cached.signature == signature {
            cacheLock.unlock()
            return cached.foundTokenEvent ? cached.tokens : nil
        }

        let cached = sessionTokenTotalCache[path]
        cacheLock.unlock()

        let scanStart: UInt64
        let initialTotal: Int
        let initialPendingLine: String
        let hadTokenEvent: Bool
        if let cached,
           cached.bytesScanned < signature.size,
           cached.signature.modifiedAt <= signature.modifiedAt {
            scanStart = cached.bytesScanned
            initialTotal = cached.tokens
            initialPendingLine = cached.pendingLine
            hadTokenEvent = cached.foundTokenEvent
        } else {
            scanStart = 0
            initialTotal = 0
            initialPendingLine = ""
            hadTokenEvent = false
        }

        guard let scan = scanSessionTokenTotal(
            from: path,
            startingAt: scanStart,
            endingAt: signature.size,
            initialTotal: initialTotal,
            initialPendingLine: initialPendingLine,
            hadTokenEvent: hadTokenEvent
        ) else {
            return nil
        }

        cacheLock.lock()
        sessionTokenTotalCache[path] = SessionTokenTotalCache(
            signature: signature,
            bytesScanned: scan.bytesScanned,
            tokens: scan.tokens,
            pendingLine: scan.pendingLine,
            foundTokenEvent: scan.foundTokenEvent
        )
        cacheLock.unlock()
        return scan.foundTokenEvent ? scan.tokens : nil
    }

    private func scanSessionTokenTotal(
        from path: String,
        startingAt: UInt64 = 0,
        endingAt: UInt64,
        initialTotal: Int = 0,
        initialPendingLine: String = "",
        hadTokenEvent: Bool = false
    ) -> SessionTokenScanResult? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard startingAt <= endingAt else {
            return nil
        }

        do {
            try handle.seek(toOffset: startingAt)
        } catch {
            return nil
        }

        var pending = initialPendingLine
        var total = initialTotal
        var foundTokenEvent = hadTokenEvent
        var bytesScanned = startingAt

        while bytesScanned < endingAt {
            let data: Data
            do {
                let remaining = endingAt - bytesScanned
                let chunkSize = Int(min(UInt64(1024 * 1024), remaining))
                data = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if data.isEmpty {
                break
            }
            bytesScanned += UInt64(data.count)

            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
            guard let lastLine = lines.last else {
                continue
            }
            pending = String(lastLine)

            for line in lines.dropLast() where line.contains(#""token_count""#) {
                guard let event = parseTokenCountEvent(String(line)) else {
                    continue
                }
                total += event.tokens
                foundTokenEvent = true
            }
        }

        if pending.contains(#""token_count""#),
           let event = parseTokenCountEvent(pending) {
            total += event.tokens
            pending = ""
            foundTokenEvent = true
        }

        return SessionTokenScanResult(
            bytesScanned: bytesScanned,
            tokens: total,
            pendingLine: pending,
            foundTokenEvent: foundTokenEvent
        )
    }

    private func filePrefix(from path: String, maxBytes: Int) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer {
                try? handle.close()
            }
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func fileSuffix(from path: String, maxBytes: UInt64) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer {
                try? handle.close()
            }

            let fileSize = try handle.seekToEnd()
            let start = fileSize > maxBytes ? fileSize - maxBytes : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func sessionMeta(from path: String) -> SessionMetaInfo? {
        guard let text = filePrefix(from: path, maxBytes: 256 * 1024) else {
            return nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""session_meta""#) else {
                continue
            }

            let lineText = String(line)
            guard let data = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                if let fallback = fallbackSessionMeta(from: lineText) {
                    return fallback
                }
                continue
            }

            let source = payload["source"] as? [String: Any]
            let subagentSource = source?["subagent"] as? [String: Any]
            let hasSubagentSource = subagentSource != nil
            let threadSource = payload["thread_source"] as? String
            let threadSpawn = subagentSource?["thread_spawn"] as? [String: Any]
            let parentThreadID = (
                payload["parent_thread_id"] as? String
                    ?? payload["parentThreadId"] as? String
                    ?? threadSpawn?["parent_thread_id"] as? String
                    ?? threadSpawn?["parentThreadId"] as? String
            )?.lowercased()
            let isSubagent = threadSource == "subagent" || hasSubagentSource

            return SessionMetaInfo(
                isSubagent: isSubagent,
                parentThreadID: isSubagent ? parentThreadID : nil
            )
        }

        return nil
    }

    private func fallbackSessionMeta(from line: String) -> SessionMetaInfo? {
        guard line.range(of: #""type"\s*:\s*"session_meta""#, options: .regularExpression) != nil else {
            return nil
        }

        let threadSource = jsonStringValue(for: "thread_source", in: line)
        let hasSubagentSource = line.range(
            of: #""source"\s*:\s*\{\s*"subagent"\s*:"#,
            options: .regularExpression
        ) != nil
        let isSubagent = threadSource == "subagent" || hasSubagentSource
        guard isSubagent else {
            return SessionMetaInfo(isSubagent: false, parentThreadID: nil)
        }

        return SessionMetaInfo(
            isSubagent: true,
            parentThreadID: (
                jsonStringValue(for: "parent_thread_id", in: line)
                    ?? jsonStringValue(for: "parentThreadId", in: line)
            )?.lowercased()
        )
    }

    private func jsonStringValue(for key: String, in line: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"""# + escapedKey + #""\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange])
    }

    private func sessionRuntimeInfo(from path: String) -> SessionRuntimeInfo? {
        guard let text = filePrefix(from: path, maxBytes: 1_024 * 1_024) else {
            return nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""turn_context""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            let model = stringValue(payload["model"]) ?? stringValue(settings?["model"])
            let reasoningEffort = stringValue(payload["effort"])
                ?? stringValue(payload["reasoning_effort"])
                ?? stringValue(settings?["reasoning_effort"])

            if model != nil || reasoningEffort != nil {
                return SessionRuntimeInfo(model: model, reasoningEffort: reasoningEffort)
            }
        }

        return nil
    }

    private func candidateRateLimitPaths(from threads: [ThreadRecord], recentLimit: Int = 4) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for path in threads.map(\.rolloutPath) + recentSessionPaths(limit: recentLimit) {
            guard !path.isEmpty, seen.insert(path).inserted else {
                continue
            }
            paths.append(path)
        }

        return paths
    }

    private func recentSessionActivityWatchPaths(limit: Int = 80) -> [String] {
        let paths = recentTaskSessionPaths(limit: limit)
        let directories = paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return paths + directories
    }

    private func uniqueExistingPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard !path.isEmpty else {
                return nil
            }
            let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: normalizedPath),
                  seen.insert(normalizedPath).inserted else {
                return nil
            }
            return normalizedPath
        }
    }

    private func recentTaskSessionPaths(limit: Int) -> [String] {
        cacheLock.lock()
        let cachedPaths = recentTaskPathsCache
        cacheLock.unlock()

        if let cachedPaths,
           Date().timeIntervalSince(cachedPaths.createdAt) < 5 {
            return Array(cachedPaths.paths.prefix(limit))
        }

        let paths = collectRecentSessionPaths(
            roots: [codexDirectory.appendingPathComponent("sessions")],
            limit: limit
        )

        cacheLock.lock()
        recentTaskPathsCache = RecentPathsCache(createdAt: Date(), paths: paths)
        cacheLock.unlock()

        return Array(paths.prefix(limit))
    }

    private func recentSessionPaths(limit: Int) -> [String] {
        cacheLock.lock()
        let cachedPaths = recentPathsCache
        cacheLock.unlock()

        if let cachedPaths,
           Date().timeIntervalSince(cachedPaths.createdAt) < 5 {
            return Array(cachedPaths.paths.prefix(limit))
        }

        let roots = [
            codexDirectory.appendingPathComponent("sessions"),
            codexDirectory.appendingPathComponent("archived_sessions")
        ]

        let paths = collectRecentSessionPaths(roots: roots, limit: max(limit, 8))

        cacheLock.lock()
        recentPathsCache = RecentPathsCache(createdAt: Date(), paths: paths)
        cacheLock.unlock()

        return Array(paths.prefix(limit))
    }

    private func sessionPath(for sessionID: String) -> String? {
        let normalized = sessionID.lowercased()
        let roots = [
            codexDirectory.appendingPathComponent("sessions"),
            codexDirectory.appendingPathComponent("archived_sessions")
        ]
        return collectRecentSessionPaths(roots: roots, limit: 1_000)
            .first { path in
                self.sessionID(from: path)?.lowercased() == normalized
            }
    }

    private func collectRecentSessionPaths(roots: [URL], limit: Int) -> [String] {
        var files: [(path: String, modifiedAt: Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else {
                    continue
                }
                files.append((url.path, values.contentModificationDate ?? .distantPast))
            }
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map(\.path)
    }

    private func localizedEffort(_ effort: String?) -> String {
        switch effort {
        case "none":
            "无推理"
        case "minimal":
            "极低推理"
        case "low":
            "低推理"
        case "medium":
            "中等推理"
        case "high":
            "高推理"
        case "xhigh":
            "超高推理"
        case let value? where !value.isEmpty:
            value
        default:
            "推理未知"
        }
    }

    private func loadRateLimits(from paths: [String], source: RateLimitSourcePreference, now: Date) -> RateLimitSnapshot {
        switch source {
        case .appServerFirst:
            loadAppServerRateLimits(now: now) ?? loadLatestRateLimits(from: paths)
        case .localFilesOnly:
            loadLatestRateLimits(from: paths)
        }
    }

    private func loadLatestRateLimits(from paths: [String]) -> RateLimitSnapshot {
        let snapshots = paths
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            .compactMap { readRateLimitSnapshot(from: $0) }

        if let codexSnapshot = snapshots
            .filter(\.isPrimaryCodexLimit)
            .max(by: { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }) {
            return codexSnapshot
        }

        if let latestSnapshot = snapshots
            .max(by: { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }) {
            return latestSnapshot
        }

        return RateLimitSnapshot(
            primaryPercent: nil,
            secondaryPercent: nil,
            primaryResetsAt: nil,
            secondaryResetsAt: nil,
            capturedAt: nil,
            isPrimaryCodexLimit: false
        )
    }

    private func loadAppServerRateLimits(now: Date) -> RateLimitSnapshot? {
        cacheLock.lock()
        let cached = appServerRateLimitCache
        cacheLock.unlock()

        if let cached {
            switch cached.state {
            case .success(let snapshot) where now.timeIntervalSince(cached.createdAt) < UsageScanPolicy.appServerSuccessCacheTTL:
                return snapshot
            case .failure where now.timeIntervalSince(cached.createdAt) < UsageScanPolicy.appServerFailureCacheTTL:
                return nil
            default:
                break
            }
        }

        guard FileManager.default.fileExists(atPath: appServerExecutable) else {
            cacheAppServerRateLimits(.failure, now: now)
            return nil
        }

        let output = try? Shell.run("/bin/zsh", ["-lc", appServerRateLimitScript()], timeout: 4)
        guard let output,
              let snapshot = parseAppServerRateLimits(output: output, now: now) else {
            cacheAppServerRateLimits(.failure, now: now)
            return nil
        }

        cacheAppServerRateLimits(.success(snapshot), now: now)
        return snapshot
    }

    private func cacheAppServerRateLimits(_ state: AppServerRateLimitCache.State, now: Date) {
        cacheLock.lock()
        appServerRateLimitCache = AppServerRateLimitCache(createdAt: now, state: state)
        cacheLock.unlock()
    }

    private func appServerRateLimitScript() -> String {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-notch","version":"0.1.1"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized"}"#
        let readRateLimits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#

        return """
        {
          printf '%s\\n' '\(initialize)' '\(initialized)' '\(readRateLimits)'
          sleep 2.2
        } | '\(appServerExecutable)' app-server --stdio
        """
    }

    private func parseAppServerRateLimits(output: String, now: Date) -> RateLimitSnapshot? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains(#""id":2"#),
                  let data = line.data(using: .utf8),
                  let response = try? JSONDecoder().decode(AppServerRateLimitResponse.self, from: data),
                  let result = response.result else {
                continue
            }

            let snapshot = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
            guard snapshot.limitId == nil || snapshot.limitId == "codex" else {
                continue
            }

            return RateLimitSnapshot(
                primaryPercent: remainingPercent(fromUsedPercent: snapshot.primary?.usedPercent),
                secondaryPercent: remainingPercent(fromUsedPercent: snapshot.secondary?.usedPercent),
                primaryResetsAt: snapshot.primary?.resetsAt,
                secondaryResetsAt: snapshot.secondary?.resetsAt,
                capturedAt: now,
                isPrimaryCodexLimit: true
            )
        }

        return nil
    }

    private func readRateLimitSnapshot(from rolloutPath: String) -> RateLimitSnapshot? {
        guard let output = tokenCountLines(from: rolloutPath, lineLimit: 600) else {
            return nil
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        for line in lines {
            guard line.contains("\"token_count\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let capturedAt = parseTimestamp(timestamp),
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let limitID = rateLimits["limit_id"] as? String
            let primary = rateLimits["primary"] as? [String: Any]
            let secondary = rateLimits["secondary"] as? [String: Any]
            let primaryPercent = remainingPercent(fromUsedPercent: primary?["used_percent"])
            let secondaryPercent = remainingPercent(fromUsedPercent: secondary?["used_percent"])
            let primaryResetsAt = intValue(primary?["resets_at"])
            let secondaryResetsAt = intValue(secondary?["resets_at"])

            if primaryPercent != nil || secondaryPercent != nil {
                return RateLimitSnapshot(
                    primaryPercent: primaryPercent,
                    secondaryPercent: secondaryPercent,
                    primaryResetsAt: primaryResetsAt,
                    secondaryResetsAt: secondaryResetsAt,
                    capturedAt: capturedAt,
                    isPrimaryCodexLimit: limitID == "codex"
                )
            }
        }

        return nil
    }

    private func extractTokenCount(from text: String) -> Int? {
        guard let match = text.firstMatch(of: tokenPattern) else {
            return nil
        }
        return Int(match.1)
    }

    private func tokenCountLines(from rolloutPath: String, lineLimit: Int) -> String? {
        guard FileManager.default.fileExists(atPath: rolloutPath) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath))
            defer {
                try? handle.close()
            }

            let fileSize = try handle.seekToEnd()
            let bytesPerLine = UsageScanPolicy.estimatedTokenLineBytes
            let maxBytes = min(fileSize, UInt64(lineLimit) * bytesPerLine)
            try handle.seek(toOffset: fileSize - maxBytes)
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { $0.contains("\"token_count\"") }
                .suffix(lineLimit)

            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func parseTokenCountEvent(_ line: String) -> (date: Date, tokens: Int)? {
        if lineContainsTokenCountPayload(line),
           let timestamp = fastJSONStringValue(for: "timestamp", in: line),
           let date = parseTimestamp(timestamp),
           let tokens = fastLastTokenUsageTotal(in: line) {
            return (date, tokens)
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseTimestamp(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let tokens = intValue(lastUsage["total_tokens"]) else {
            return nil
        }

        return (date, tokens)
    }

    private func lineContainsTokenCountPayload(_ line: String) -> Bool {
        line.contains(#""type":"token_count""#)
            || line.contains(#""type": "token_count""#)
            || line.contains(#""type" : "token_count""#)
    }

    private func fastLastTokenUsageTotal(in line: String) -> Int? {
        guard let usageRange = line.range(of: #""last_token_usage""#),
              let tokenRange = line[usageRange.upperBound...].range(of: #""total_tokens""#),
              let colonRange = line[tokenRange.upperBound...].range(of: ":") else {
            return nil
        }

        var index = colonRange.upperBound
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let start = index
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }

        guard start < index else {
            return nil
        }
        return Int(line[start..<index])
    }

    private func fastJSONStringValue(for key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: #"""# + key + #"""#),
              let colonRange = line[keyRange.upperBound...].range(of: ":"),
              let quoteStart = line[colonRange.upperBound...].firstIndex(of: "\"") else {
            return nil
        }

        var index = line.index(after: quoteStart)
        var value = ""
        var isEscaped = false

        while index < line.endIndex {
            let character = line[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }

        return nil
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func makeUsageSignature(for rolloutPaths: [String]) -> StoreSignature? {
        let databasePaths = sqliteFileSet(stateDatabase) + sqliteFileSet(logsDatabase) + [sessionIndexPath]
        let paths = databasePaths + rolloutPaths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return nil
        }

        return StoreSignature(files: paths.map(fileSignature).sorted { $0.path < $1.path })
    }

    private func makeSignature(for rolloutPaths: [String]) -> StoreSignature? {
        let databasePaths = sqliteFileSet(stateDatabase) + sqliteFileSet(logsDatabase) + [sessionIndexPath]
        let paths = databasePaths + rolloutPaths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return nil
        }

        return StoreSignature(files: paths.map(fileSignature).sorted { $0.path < $1.path })
    }

    private func sqliteFileSet(_ database: String) -> [String] {
        [
            database,
            "\(database)-wal",
            "\(database)-shm"
        ]
    }

    private func fileSignature(_ path: String) -> FileSignature {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return FileSignature(path: path, exists: false, size: 0, modifiedAt: 0)
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileSignature(path: path, exists: true, size: size, modifiedAt: modifiedAt)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double.rounded())
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func remainingPercent(fromUsedPercent value: Any?) -> Int? {
        guard let usedPercent = intValue(value) else {
            return nil
        }
        return min(100, max(0, 100 - usedPercent))
    }
}

private struct FastSnapshotCache {
    let createdAt: Date
    let signature: StoreSignature
    let rolloutPaths: [String]
    let threads: [ThreadRecord]
    let activeThreadIDs: Set<String>
    let rateLimits: RateLimitSnapshot
    let rateLimitSource: RateLimitSourcePreference
    let taskHistoryRange: TaskHistoryRange
}

private struct RecentPathsCache {
    let createdAt: Date
    let paths: [String]
}

private struct SessionTokenTotalCache {
    let signature: FileSignature
    let bytesScanned: UInt64
    let tokens: Int
    let pendingLine: String
    let foundTokenEvent: Bool
}

private struct SessionTokenScanResult {
    let bytesScanned: UInt64
    let tokens: Int
    let pendingLine: String
    let foundTokenEvent: Bool
}

private struct RecentSessionCandidate {
    let path: String
    let sessionID: String
    let modifiedAt: Date
    let updatedAt: Int
    let databaseTokens: Int
}

private struct AppServerRateLimitCache {
    let createdAt: Date
    let state: State

    enum State {
        case success(RateLimitSnapshot)
        case failure
    }
}

private struct PeriodUsageCache {
    let createdAt: Date
    let signature: StoreSignature
    let usage: PeriodUsage
}

private struct SessionMetaInfo {
    let isSubagent: Bool
    let parentThreadID: String?
}

private struct SessionRuntimeInfo {
    let model: String?
    let reasoningEffort: String?
}

private struct AppServerRateLimitResponse: Decodable {
    let id: Int?
    let result: AppServerRateLimitResult?
}

private struct AppServerRateLimitResult: Decodable {
    let rateLimits: AppServerRateLimitSnapshot
    let rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
}

private struct AppServerRateLimitSnapshot: Decodable {
    let limitId: String?
    let primary: AppServerRateLimitWindow?
    let secondary: AppServerRateLimitWindow?
}

private struct AppServerRateLimitWindow: Decodable {
    let usedPercent: Int
    let resetsAt: Int?
}

private struct StoreSignature: Equatable {
    let files: [FileSignature]
}

private struct FileSignature: Equatable {
    let path: String
    let exists: Bool
    let size: UInt64
    let modifiedAt: TimeInterval
}

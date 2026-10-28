import Foundation

// Keep each published scoring contract separate; a retained three-task file is not a four-task fallback.
enum CodexRadarPublicDocument: Codable {
    case four(CodexRadarFourTaskDocument)

    static func snapshots(data: Data, fetchedAt: Date) throws -> [CodexRadarTask: CodexRadarSnapshot] {
        if let document = try? JSONDecoder().decode(Self.self, from: data) {
            switch document {
            case .four(let document): return try document.snapshots(fetchedAt: fetchedAt)
            }
        }
        return try CodexRadarThreeTaskDocument.decode(data).snapshots(fetchedAt: fetchedAt)
    }
}

struct CodexRadarFourTaskDocument: Codable, Sendable {
    let payload: Payload
    let totals: [CodexRadarThreeTaskDocument.Total]
    static let components: [CodexRadarTask] = [.combined, .pompeii, .pelican, .candy]

    struct Payload: Codable, Sendable {
        let schema: String
        let `protocol`: String
        let roundId: String
        let verifiedAt: String
        let scoreSnapshotAt: String?
        let expected: Int
        let graded: Int
        let configurations: Int
        let models: [String]
        let modelEfforts: [String: [String]]
        let modelNames: [String: String]
        let efforts: [String]
        let taskWeights: [String: Double]
        let scoreMax: Double
        let rows: [Row]
    }

    struct Row: Codable, Sendable {
        let model: String
        let effort: String
        let combined: Result?
        let pompeii: Result?
        let pelican: Result?
        let candy: Result?
        var id: String { "\(model)|\(effort)" }

        func result(for task: CodexRadarTask) -> Result? {
            switch task {
            case .total: nil
            case .combined: combined
            case .pompeii: pompeii
            case .pelican: pelican
            case .candy: candy
            }
        }
    }

    struct Result: Codable, Sendable {
        let selector: String
        let executionId: String?
        let score100: Double?
        let score: Double?
        let correct: Bool?
        let rubric: String?
        let completionCap: Double?
        let costUsd: Double?
        let costKind: String?
        let modelElapsedSeconds: Double?
        let modelStartedAt: String?
        let modelCompletedAt: String?

        func grade(for task: CodexRadarTask) -> Double? {
            switch task {
            case .total: nil
            case .combined, .pelican: score
            case .pompeii: score100
            case .candy: correct.map { $0 ? 100 : 0 }
            }
        }

        var rubricLabel: String? {
            switch rubric {
            case "pelican-candy-static-standalone-v1-20261027",
                 "pelican-animation-standalone-v1-20261027": "独立v1"
            case "pelican-animation-standalone-v2-visible-evidence-20261027": "可见v2"
            default: nil
            }
        }

        var cost: Double? { costKind == "api_equivalent_estimate" ? costUsd : nil }

        // Four-task data has no time_scope field. Verify the stated native duration against its timestamps.
        var duration: Double? {
            guard let seconds = modelElapsedSeconds,
                  let start = modelStartedAt.flatMap(CodexRadarDateParser.parse),
                  let end = modelCompletedAt.flatMap(CodexRadarDateParser.parse),
                  end >= start, abs(end.timeIntervalSince(start) - seconds) <= 0.1 else { return nil }
            return seconds
        }

        func validate(for task: CodexRadarTask) throws {
            let selectors: [CodexRadarTask: String] = [
                .combined: "visual-reasoning:pelican-candy-svg-20261027",
                .pompeii: "pompeii:pompeii-adjacency-rp-040",
                .pelican: "visual:pelican-bicycle",
                .candy: "local-reasoning:candy-cross-shape"
            ]
            guard selector == selectors[task],
                  [score100, score, completionCap].compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...100).contains($0) }),
                  [costUsd, modelElapsedSeconds].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }),
                  grade(for: task) == nil || executionId?.isEmpty == false else {
                throw CodexRadarClientError.invalidResponse
            }
            if let score = grade(for: task), task == .combined || task == .pelican {
                let known = task == .combined
                    ? rubric == "pelican-candy-static-standalone-v1-20261027"
                    : ["pelican-animation-standalone-v1-20261027", "pelican-animation-standalone-v2-visible-evidence-20261027"].contains(rubric ?? "")
                guard known else { throw CodexRadarClientError.unsupportedFormat }
                if let completionCap, score > completionCap { throw CodexRadarClientError.invalidResponse }
            }
        }
    }

    static func assemble(homepage: Data, source: Data) throws -> Self {
        guard homepage.count <= 8_000_000, source.count <= 8_000_000,
              let html = String(data: homepage, encoding: .utf8) else { throw CodexRadarClientError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: source)
        let pattern = #"(?is)<(?:div|section)\b[^>]*\bdata-cir-panel\s*=\s*["']total["'][^>]*>(.*?)</table\s*>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: html) else {
            throw CodexRadarClientError.unsupportedFormat
        }
        let document = Self(payload: payload, totals: try CodexRadarThreeTaskDocument.publishedTotals(in: String(html[range])))
        _ = try document.snapshots(fetchedAt: Date())
        return document
    }

    func encode() throws -> Data { try JSONEncoder().encode(CodexRadarPublicDocument.four(self)) }

    func snapshots(fetchedAt: Date) throws -> [CodexRadarTask: CodexRadarSnapshot] {
        guard payload.schema == "codex-four-task-results/1", payload.protocol == "codex-four-weighted-150-v2",
              payload.scoreMax == 150,
              payload.taskWeights == ["combined": 60, "pompeii": 45, "pelican": 22.5, "candy": 22.5] else {
            throw CodexRadarClientError.unsupportedFormat
        }
        let supportedIDs = payload.modelEfforts.flatMap { model, efforts in efforts.map { "\(model)|\($0)" } }
        guard !payload.roundId.isEmpty, (1...1000).contains(payload.configurations),
              payload.rows.count == payload.configurations, payload.expected == payload.configurations * 4,
              (0...payload.expected).contains(payload.graded),
              Set(payload.models).count == payload.models.count, !payload.models.isEmpty,
              Set(payload.modelEfforts.keys) == Set(payload.models),
              !payload.efforts.isEmpty, Set(payload.efforts).count == payload.efforts.count,
              payload.modelEfforts.values.allSatisfy({ !$0.isEmpty && Set($0).isSubset(of: Set(payload.efforts)) }),
              Set(supportedIDs).count == supportedIDs.count,
              Set(payload.rows.map(\.id)) == Set(supportedIDs), Set(payload.rows.map(\.id)).count == payload.rows.count,
              Set(totals.map(\.id)) == Set(supportedIDs), totals.count == payload.rows.count,
              let verifiedAt = CodexRadarDateParser.parse(payload.verifiedAt),
              let updatedAt = payload.scoreSnapshotAt.map(CodexRadarDateParser.parse) ?? verifiedAt else {
            throw CodexRadarClientError.invalidResponse
        }
        var graded = 0
        for row in payload.rows {
            for task in Self.components {
                if let result = row.result(for: task) {
                    try result.validate(for: task)
                    if result.grade(for: task) != nil { graded += 1 }
                }
            }
        }
        guard graded == payload.graded else { throw CodexRadarClientError.invalidResponse }
        let rowsByID = Dictionary(uniqueKeysWithValues: payload.rows.map { ($0.id, $0) })
        var snapshots: [CodexRadarTask: CodexRadarSnapshot] = [:]
        for task in [.total] + Self.components {
            var completed = 0
            let cards = try totals.map { total -> CodexRadarModelScore in
                let row = rowsByID[total.id]!
                let result = row.result(for: task)
                let grade = task == .total ? total.score : result?.grade(for: task)
                let results = task == .total ? Self.components.compactMap { row.result(for: $0) } : [result].compactMap { $0 }
                if task == .total, let score = grade {
                    let parts = Self.components.compactMap { part -> Double? in
                        row.result(for: part)?.grade(for: part).map { $0 * payload.taskWeights[part.rawValue]! / 100 }
                    }
                    guard parts.count == 4, score.isFinite, (0...150).contains(score),
                          abs(score - parts.reduce(0, +)) <= 0.0051 else { throw CodexRadarClientError.inconsistentSources }
                }
                if grade != nil { completed += 1 }
                let costs = results.compactMap(\.cost)
                let durations = results.compactMap(\.duration)
                let count = task == .total ? 4 : 1
                let correct = task == .candy ? result?.correct : nil
                return CodexRadarModelScore(id: row.id, label: "\(payload.modelNames[row.model] ?? row.model) \(row.effort)",
                    score: task == .candy ? nil : grade,
                    status: grade == nil ? "待测" : result?.rubricLabel,
                    passed: nil, tasks: nil,
                    costUSD: costs.count == count ? costs.reduce(0, +) : nil,
                    wallTime: durations.count == count ? String(format: "耗时 %.2f 分钟", durations.reduce(0, +) / 60) : nil,
                    sampleLabel: task == .total ? "/150" : task == .candy ? nil : "/100",
                    scoreText: task == .total ? grade.map { String(format: "%.2f", $0) } : correct.map { $0 ? "正确" : "错误" },
                    scoreIsCorrect: correct, costIsEstimate: true)
            }
            var snapshot = CodexRadarSnapshot.loading
            snapshot.state = completed == payload.configurations ? .ready : .stale
            snapshot.models = cards
            snapshot.monitoredAt = updatedAt
            snapshot.fetchedAt = fetchedAt
            snapshot.status = "\(task.title) · \(completed)/\(payload.configurations) 档"
            snapshot.dataSource = .publicFourTask
            snapshot.siteURL = URL(string: "https://codexradar.com/#stationmaster-round")!
            snapshot.message = completed == payload.configurations ? nil : "官网\(task.title)已公布 \(completed)/\(payload.configurations) 档；缺项保持未知，5分钟后重试"
            snapshots[task] = snapshot
        }
        return snapshots
    }
}

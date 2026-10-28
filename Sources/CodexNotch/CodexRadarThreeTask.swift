import Foundation

enum CodexRadarTask: String, CaseIterable, Sendable {
    case total, combined, pompeii, pelican, candy

    static let components: [Self] = [.pompeii, .pelican, .candy]

    var title: String {
        switch self {
        case .total: "总分"
        case .combined: "秦始皇"
        case .pompeii: "庞贝"
        case .pelican: "鹈鹕"
        case .candy: "糖果"
        }
    }

    func explanation(for source: CodexRadarDataSource) -> String {
        if source == .publicFourTask {
            switch self {
            case .total: return "官网总分 /150：秦始皇60、庞贝45、鹈鹕22.5、糖果22.5；费用和耗时为四题合计。"
            case .combined: return "秦始皇 /100；采用完成度门槛后的最终分，按60分计入总分。"
            case .pompeii: return "庞贝 /100，按45分计入总分。"
            case .pelican: return "鹈鹕 /100，按22.5分计入总分；独立v1 / 可见证据v2。"
            case .candy: return "糖果按对错展示，答对计22.5分，答错计0分。"
            }
        }
        return legacyExplanation
    }

    private var legacyExplanation: String {
        switch self {
        case .total: "官网总分 /150，三题等权各50分；费用和耗时为三题合计。"
        case .combined: "秦始皇 /100。"
        case .pompeii: "庞贝分项 /100。"
        case .pelican: "鹈鹕分项 /100；卡片标注评分规则 v2/v3。"
        case .candy: "糖果题按对错展示。"
        }
    }
}

// Read the same inert JSON payload used by the official homepage. Never execute scripts.
struct CodexRadarThreeTaskPayload: Codable, Sendable {
    let schema: String
    let `protocol`: String
    let viewId: String
    let configurations: Int
    let graded: Int
    let expected: Int
    let taskCount: Int
    let noCombinedScore: Bool
    let integratedVerifiedAt: String
    let models: [String]
    let modelNames: [String: String]
    let efforts: [String]
    let rows: [Row]

    struct Row: Codable, Sendable {
        let model: String
        let effort: String
        let pompeii: Result?
        let pelican: Result?
        let candy: Result?

        func result(for task: CodexRadarTask) -> Result? {
            switch task {
            case .total, .combined: nil
            case .pompeii: pompeii
            case .pelican: pelican
            case .candy: candy
            }
        }
        var id: String { "\(model)|\(effort)" }
    }

    struct Result: Codable, Sendable {
        let selector: String
        let sourceRoundId: String
        let score100: Double?
        let score: Double?
        let correct: Bool?
        let rubric: String?
        let costUsd: Double?
        let costKind: String?
        let modelElapsedSeconds: Double?
        let timeScope: String?

        func hasGrade(for task: CodexRadarTask) -> Bool {
            switch task {
            case .total, .combined: false
            case .pompeii: score100 != nil
            case .pelican: score != nil
            case .candy: correct != nil
            }
        }

        func validate(for task: CodexRadarTask) throws {
            let expectedSelector: String
            switch task {
            case .total, .combined: throw CodexRadarClientError.invalidResponse
            case .pompeii: expectedSelector = "pompeii:pompeii-adjacency-rp-040"
            case .pelican: expectedSelector = "visual:pelican-bicycle"
            case .candy: expectedSelector = "local-reasoning:candy-cross-shape"
            }
            guard selector == expectedSelector, !sourceRoundId.isEmpty,
                  [score100, score].compactMap({ $0 }).allSatisfy({ $0.isFinite && (0...100).contains($0) }),
                  [costUsd, modelElapsedSeconds].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw CodexRadarClientError.invalidResponse
            }
            if task == .pelican, score != nil, rubricLabel == nil {
                throw CodexRadarClientError.unsupportedFormat
            }
        }

        var rubricLabel: String? {
            switch rubric {
            case "pelican-strict-v2-20261023": "v2"
            case "pelican-strict-v3-no-coordination-cap-20261026": "v3"
            default: nil
            }
        }
    }

    static func extract(from htmlData: Data) throws -> Data {
        guard htmlData.count <= 8_000_000, let html = String(data: htmlData, encoding: .utf8) else {
            throw CodexRadarClientError.invalidResponse
        }
        let pattern = #"(?is)<script\b(?=[^>]*\btype\s*=\s*["']application/json["'])(?=[^>]*\sdata-cir-scores(?:\s|=|>))[^>]*>(.*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: html) else {
            throw CodexRadarClientError.unsupportedFormat
        }
        return Data(html[range].utf8)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }

    func snapshots(fetchedAt: Date) throws -> [CodexRadarTask: CodexRadarSnapshot] {
        guard schema == "codex-three-task-results/1", `protocol` == "codex-independent-three-v1",
              noCombinedScore, taskCount == 3, !viewId.isEmpty else { throw CodexRadarClientError.unsupportedFormat }
        guard (1...1000).contains(configurations), rows.count == configurations,
              expected == configurations * taskCount, (0...expected).contains(graded),
              Set(rows.map(\.id)).count == rows.count,
              !models.isEmpty, Set(models).count == models.count,
              !efforts.isEmpty, Set(efforts).count == efforts.count,
              Set(rows.map(\.model)) == Set(models),
              rows.allSatisfy({ models.contains($0.model) && efforts.contains($0.effort) }),
              let updatedAt = CodexRadarDateParser.parse(integratedVerifiedAt) else {
            throw CodexRadarClientError.invalidResponse
        }
        var gradeCount = 0
        for row in rows {
            for task in CodexRadarTask.components {
                if let result = row.result(for: task) {
                    try result.validate(for: task)
                    if result.hasGrade(for: task) { gradeCount += 1 }
                }
            }
        }
        guard gradeCount == graded else { throw CodexRadarClientError.invalidResponse }
        var snapshots: [CodexRadarTask: CodexRadarSnapshot] = [:]
        for task in CodexRadarTask.components {
            let completed = rows.filter { $0.result(for: task)?.hasGrade(for: task) == true }.count
            // Keep the site's model/effort order: especially avoid implying a shared pelican v2/v3 ranking.
            let cards = rows.map { row -> CodexRadarModelScore in
                let result = row.result(for: task)
                let cost = result?.costKind == "api_equivalent_estimate" ? result?.costUsd : nil
                let seconds = result?.timeScope == "native_model_start_to_end_excludes_queue_and_judge"
                    ? result?.modelElapsedSeconds : nil
                let correctness = task == .candy ? result?.correct : nil
                return CodexRadarModelScore(
                    id: row.id, label: "\(modelNames[row.model] ?? row.model) \(row.effort)",
                    score: task == .pompeii ? result?.score100 : task == .pelican ? result?.score : nil,
                    status: result?.hasGrade(for: task) == true ? (task == .pelican ? result?.rubricLabel : nil) : "待测",
                    passed: nil, tasks: nil, costUSD: cost,
                    wallTime: seconds.map { String(format: "耗时 %.1f 秒", $0) },
                    sampleLabel: task == .candy ? nil : "/100",
                    scoreText: correctness.map { $0 ? "正确" : "错误" },
                    scoreIsCorrect: correctness, costIsEstimate: true
                )
            }
            var snapshot = CodexRadarSnapshot.loading
            snapshot.state = completed == configurations ? .ready : .stale
            snapshot.models = cards
            snapshot.monitoredAt = updatedAt
            snapshot.fetchedAt = fetchedAt
            snapshot.status = "\(task.title) · \(completed)/\(configurations) 档"
            snapshot.dataSource = .publicThreeTask
            snapshot.siteURL = URL(string: "https://codexradar.com/#stationmaster-round")!
            snapshot.message = completed == configurations ? nil : "官网本题已公布 \(completed)/\(configurations) 档；未公布结果显示待测，5分钟后重试"
            snapshots[task] = snapshot
        }
        return snapshots
    }
}

// Cache the source data together with the total scores actually published on the homepage.
// The JSON file still says no_combined_score: true; never infer totals from that file alone.
struct CodexRadarThreeTaskDocument: Codable, Sendable {
    let payload: CodexRadarThreeTaskPayload
    let totals: [Total]?

    struct Total: Codable, Sendable {
        let id: String
        let score: Double?
    }

    static func assemble(homepage: Data, source: Data) throws -> Self {
        let payload = try CodexRadarThreeTaskPayload.decode(source)
        _ = try payload.snapshots(fetchedAt: Date())
        guard let html = String(data: homepage, encoding: .utf8), homepage.count <= 8_000_000 else {
            throw CodexRadarClientError.invalidResponse
        }
        let panelPattern = #"(?is)<(?:div|section)\b[^>]*\bdata-cir-panel\s*=\s*["']total["'][^>]*>(.*?)</table\s*>"#
        let regex = try NSRegularExpression(pattern: panelPattern)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            // Only the explicitly embedded independent view may omit a total panel.
            guard (try? CodexRadarThreeTaskPayload.extract(from: homepage)) != nil else {
                throw CodexRadarClientError.unsupportedFormat
            }
            return Self(payload: payload, totals: nil)
        }
        guard html.contains("三题等权，总分换算为150分"), html.contains("糖果答对计满分、答错计0") else {
            throw CodexRadarClientError.unsupportedFormat
        }
        return try validated(payload: payload, totals: publishedTotals(in: String(html[range])))
    }

    private static func validated(payload: CodexRadarThreeTaskPayload, totals: [Total]) throws -> Self {
        let document = Self(payload: payload, totals: totals)
        _ = try document.snapshots(fetchedAt: Date())
        return document
    }

    static func publishedTotals(in panel: String) throws -> [Total] {
        let buttons = try NSRegularExpression(pattern: #"(?is)<button\b[^>]*\bdata-cir-setting\s*=\s*["']([^"']+)["'][^>]*>.*?<strong\b[^>]*>([^<]+)</strong>.*?</button\s*>"#)
        let totals = try buttons.matches(in: panel, range: NSRange(panel.startIndex..., in: panel)).map { match -> Total in
            guard let idRange = Range(match.range(at: 1), in: panel), let scoreRange = Range(match.range(at: 2), in: panel) else {
                throw CodexRadarClientError.invalidResponse
            }
            let value = panel[scoreRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let score = Double(value)
            guard score != nil || ["—", "--", "待测"].contains(value) else { throw CodexRadarClientError.invalidResponse }
            return Total(id: panel[idRange].replacingOccurrences(of: ":", with: "|"), score: score)
        }
        return totals
    }

    func encode() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }

    func snapshots(fetchedAt: Date) throws -> [CodexRadarTask: CodexRadarSnapshot] {
        var snapshots = try payload.snapshots(fetchedAt: fetchedAt)
        guard let totals else { return snapshots }
        guard totals.count == payload.rows.count, Set(totals.map(\.id)) == Set(payload.rows.map(\.id)),
              Set(totals.map(\.id)).count == totals.count else { throw CodexRadarClientError.invalidResponse }
        let byID = Dictionary(uniqueKeysWithValues: totals.map { ($0.id, $0) })
        var completed = 0
        var cards: [CodexRadarModelScore] = []
        for row in payload.rows {
            let published = byID[row.id]!.score
            // Verify page/file consistency using the published equal-weight policy, but display the page's value.
            if let score = published {
                guard let pompeii = row.pompeii?.score100, let pelican = row.pelican?.score, let candy = row.candy?.correct,
                      score.isFinite, (0...150).contains(score),
                      abs(score - (pompeii + pelican + (candy ? 100 : 0)) / 2) <= 0.051 else {
                    throw CodexRadarClientError.inconsistentSources
                }
                completed += 1
            }
            let results = CodexRadarTask.components.compactMap { row.result(for: $0) }
            let costs = results.compactMap { $0.costKind == "api_equivalent_estimate" ? $0.costUsd : nil }
            let durations = results.compactMap { $0.timeScope == "native_model_start_to_end_excludes_queue_and_judge" ? $0.modelElapsedSeconds : nil }
            cards.append(CodexRadarModelScore(id: row.id, label: "\(payload.modelNames[row.model] ?? row.model) \(row.effort)",
                score: published, status: published == nil ? "待测" : row.pelican?.rubricLabel, passed: nil, tasks: nil,
                costUSD: costs.count == 3 ? costs.reduce(0, +) : nil,
                wallTime: durations.count == 3 ? String(format: "耗时 %.1f 秒", durations.reduce(0, +)) : nil,
                sampleLabel: "/150", costIsEstimate: true))
        }
        var total = snapshots[.pompeii]!
        total.models = cards
        total.state = completed == payload.configurations ? .ready : .stale
        total.status = "总分 · \(completed)/\(payload.configurations) 档"
        total.message = completed == payload.configurations ? nil : "官网总分已公布 \(completed)/\(payload.configurations) 档；其余显示待测，5分钟后重试"
        snapshots[.total] = total
        return snapshots
    }
}

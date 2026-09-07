import Combine
import Foundation
import CoreFoundation

struct TokenPricingSettings: Codable, Equatable, Sendable {
    static let defaultSource = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    var automatic = true
    var intervalHours = 24
    var sourceURL = defaultSource

    var validatedURL: URL? {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }
}

enum TokenPricingError: LocalizedError {
    case invalidSource, invalidData, httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidSource: "请填写有效的 HTTPS 价格 JSON 地址"
        case .invalidData: "价格源没有完整、有效的 OpenAI 文本模型价格，已保留原价格"
        case .httpStatus(let code): "价格源返回 HTTP \(code)，已保留原价格"
        }
    }
}

enum TokenPricingParser {
    static let maximumBytes = 12 * 1_024 * 1_024

    // Read the public LiteLLM JSON format only; no remote code is loaded or run.
    static func parse(_ data: Data) throws -> [String: ModelTokenPrice] {
        guard data.count <= maximumBytes,
              let entries = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenPricingError.invalidData
        }
        var result: [String: ModelTokenPrice] = [:]
        for (name, raw) in entries {
            guard let entry = raw as? [String: Any],
                  entry["litellm_provider"] as? String == "openai",
                  ["chat", "responses"].contains(entry["mode"] as? String ?? ""),
                  !name.contains("/"), name == name.lowercased(), name.count < 200 else { continue }
            func amount(_ key: String) -> Double? {
                guard let number = entry[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0,
                      number.doubleValue <= 1 else { return nil }
                return number.doubleValue * 1_000_000
            }
            guard let input = amount("input_cost_per_token"),
                  let cached = amount("cache_read_input_token_cost"),
                  let output = amount("output_cost_per_token") else { continue }
            // Other context thresholds need their own accounting buckets. Do not
            // silently flatten such prices into a misleading standard rate.
            let tierKeys = entry.keys.filter { $0.contains("_above_") && $0.hasSuffix("_tokens") }
            guard tierKeys.allSatisfy({ $0.hasSuffix("_above_272k_tokens") }) else { continue }
            let hasLong = !tierKeys.isEmpty
            let longInput = amount("input_cost_per_token_above_272k_tokens")
            let longCached = amount("cache_read_input_token_cost_above_272k_tokens")
            let longOutput = amount("output_cost_per_token_above_272k_tokens")
            guard !hasLong || (longInput != nil && longCached != nil && longOutput != nil) else { continue }
            result[name] = ModelTokenPrice(
                inputPerMillionUSD: input, cachedInputPerMillionUSD: cached,
                outputPerMillionUSD: output, appliesLongContextSurcharge: hasLong,
                longContextInputPerMillionUSD: longInput,
                longContextCachedInputPerMillionUSD: longCached,
                longContextOutputPerMillionUSD: longOutput
            )
        }
        guard !result.isEmpty else { throw TokenPricingError.invalidData }
        return result
    }
}

struct TokenPricingCache: Codable {
    let sourceURL: String
    let checkedAt: Date
    let data: Data

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

@MainActor
final class TokenPricingUpdater: ObservableObject {
    static let shared = TokenPricingUpdater()
    @Published private(set) var settings: TokenPricingSettings
    @Published private(set) var isRefreshing = false
    @Published private(set) var status = "使用内置价格"
    @Published private(set) var lastChecked: Date?
    @Published private(set) var modelCount = 0
    @Published private(set) var activeSource: String?
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let fetch: @Sendable (URL) async throws -> Data
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var started = false
    private static let settingsKey = "modelPricingUpdateSettings.v1"

    init(
        defaults: UserDefaults = .standard,
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/codex监测/ModelPricing/current.json"),
        fetch: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.defaults = defaults
        self.cacheURL = cacheURL
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(TokenPricingSettings.self, from: $0) } ?? .init()
        self.fetch = fetch ?? { url in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https", http.statusCode == 200 else {
                throw TokenPricingError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < TokenPricingParser.maximumBytes else { throw TokenPricingError.invalidData }
                data.append(byte)
            }
            return data
        }
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(TokenPricingCache.self, from: data),
           let prices = try? TokenPricingParser.parse(cache.data) {
            apply(cache, prices: prices)
            status = "已载入上次成功更新的价格"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshIfDue()
    }

    func save(_ value: TokenPricingSettings) {
        var next = value
        next.sourceURL = next.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.intervalHours = min(168, max(1, next.intervalHours))
        guard next.validatedURL != nil else { status = TokenPricingError.invalidSource.localizedDescription; return }
        guard next != settings else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRefreshing = false
        timer?.invalidate()
        settings = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.settingsKey)
        refreshIfDue()
    }

    func refreshIfDue(now: Date = Date()) {
        guard settings.automatic else { timer?.invalidate(); return }
        let interval = Double(settings.intervalHours) * 3_600
        if activeSource != settings.sourceURL || lastChecked == nil
            || now.timeIntervalSince(lastChecked!) >= interval {
            refreshNow()
        } else {
            schedule(after: max(1, interval - now.timeIntervalSince(lastChecked!)))
        }
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        guard let url = settings.validatedURL else { status = TokenPricingError.invalidSource.localizedDescription; return }
        timer?.invalidate()
        isRefreshing = true
        status = "正在检查模型价格…"
        let currentGeneration = generation
        let fetch = fetch
        let source = settings.sourceURL
        task = Task {
            var succeeded = false
            do {
                let (data, prices) = try await Task.detached(priority: .utility) {
                    let data = try await fetch(url)
                    return (data, try TokenPricingParser.parse(data))
                }.value
                guard !Task.isCancelled, currentGeneration == generation else { return }
                let cache = TokenPricingCache(sourceURL: source, checkedAt: Date(), data: data)
                try cache.write(to: cacheURL)
                apply(cache, prices: prices)
                succeeded = true
                status = "更新成功 · \(prices.count) 个模型，未覆盖的模型使用内置价格"
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                status = "更新失败，保留原价格：\(error.localizedDescription.redactedForDisplay)"
            }
            isRefreshing = false
            task = nil
            schedule(after: succeeded ? Double(settings.intervalHours) * 3_600 : 3_600)
        }
    }

    private func apply(_ cache: TokenPricingCache, prices: [String: ModelTokenPrice]) {
        lastChecked = cache.checkedAt
        modelCount = prices.count
        activeSource = cache.sourceURL
        let sourceLabel = cache.sourceURL == TokenPricingSettings.defaultSource ? "LiteLLM" : "自定义源"
        let date = cache.checkedAt.formatted(date: .numeric, time: .shortened)
        TokenCostCatalog.install(prices, version: "\(sourceLabel) 同步 \(date) · 内置兜底 \(TokenCostCatalog.bundledPriceVersion)")
        NotificationCenter.default.post(name: .tokenPricingDidChange, object: nil)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        guard settings.automatic else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDue() }
        }
        timer.tolerance = min(60, interval * 0.1)
        self.timer = timer
    }
}

extension Notification.Name {
    static let tokenPricingDidChange = Notification.Name("TokenPricingDidChange")
}

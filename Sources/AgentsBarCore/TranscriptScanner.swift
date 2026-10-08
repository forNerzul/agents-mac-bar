import Foundation

public struct TokenCounts: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

public struct ModelUsage: Equatable, Sendable {
    public let model: String
    public let tokens: TokenCounts

    public init(model: String, tokens: TokenCounts) {
        self.model = model
        self.tokens = tokens
    }
}

public struct UsageStats: Equatable, Sendable {
    public var today: TokenCounts
    public var last7Days: TokenCounts
    /// Sorted by descending total, ties broken by model id.
    public var byModel7Days: [ModelUsage]
    public var sessionsToday: Int

    public var topModel7Days: String? { byModel7Days.first?.model }

    public init(
        today: TokenCounts = TokenCounts(),
        last7Days: TokenCounts = TokenCounts(),
        byModel7Days: [ModelUsage] = [],
        sessionsToday: Int = 0
    ) {
        self.today = today
        self.last7Days = last7Days
        self.byModel7Days = byModel7Days
        self.sessionsToday = sessionsToday
    }

    public static let empty = UsageStats()
}

public struct TranscriptScanner: Sendable {
    private let claudeDirectory: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        claudeDirectory: URL,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeDirectory = claudeDirectory
        self.calendar = calendar
        self.now = now
    }

    public static func defaultClaudeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public func scan() -> UsageStats {
        let today = calendar.startOfDay(for: now())
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: today) else { return .empty }

        var entries: [String: Entry] = [:]
        for file in transcriptFiles(modifiedSince: windowStart) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            collect(text, file: file, windowStart: windowStart, into: &entries)
        }

        var todayTotal = TokenCounts()
        var weekTotal = TokenCounts()
        var perModel: [String: TokenCounts] = [:]
        var sessions: Set<String> = []
        for entry in entries.values {
            weekTotal = weekTotal + entry.tokens
            perModel[entry.model, default: TokenCounts()] = perModel[entry.model, default: TokenCounts()] + entry.tokens
            if entry.date >= today {
                todayTotal = todayTotal + entry.tokens
                if let session = entry.sessionId { sessions.insert(session) }
            }
        }
        let byModel = perModel
            .map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { ($1.tokens.total, $0.model) < ($0.tokens.total, $1.model) }
        return UsageStats(
            today: todayTotal,
            last7Days: weekTotal,
            byModel7Days: byModel,
            sessionsToday: sessions.count
        )
    }

    private struct Entry {
        let date: Date
        let model: String
        let sessionId: String?
        let tokens: TokenCounts
    }

    /// A file cannot hold entries newer than its modification date, so older files are skipped unread.
    private func transcriptFiles(modifiedSince cutoff: Date) -> [URL] {
        let projects = claudeDirectory.appendingPathComponent("projects", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            if let modified = values.contentModificationDate, modified < cutoff { continue }
            files.append(url)
        }
        return files
    }

    private func collect(_ text: String, file: URL, windowStart: Date, into entries: inout [String: Entry]) {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            guard
                raw.contains("\"usage\""),
                let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any],
                let model = message["model"] as? String, model != "<synthetic>",
                let stamp = object["timestamp"] as? String,
                let date = (try? fractional.parse(stamp)) ?? (try? plain.parse(stamp)),
                date >= windowStart
            else { continue }

            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let tokens = TokenCounts(
                input: count("input_tokens"),
                output: count("output_tokens"),
                cacheRead: count("cache_read_input_tokens"),
                cacheWrite: count("cache_creation_input_tokens")
            )
            guard tokens.total > 0 else { continue }

            let key: String
            if let id = message["id"] as? String, !id.isEmpty {
                key = id
            } else {
                let discriminator = (object["uuid"] as? String) ?? (object["requestId"] as? String) ?? "\(lineNumber)"
                key = "\(file.path):\(discriminator)"
            }
            if let existing = entries[key], existing.tokens.total >= tokens.total { continue }
            entries[key] = Entry(
                date: date, model: model, sessionId: object["sessionId"] as? String, tokens: tokens)
        }
    }
}

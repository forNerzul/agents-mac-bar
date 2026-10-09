import Foundation

public struct UsageLimit: Equatable, Sendable {
    public let title: String
    public let percent: Double
    public let resetsAt: Date?

    public init(title: String, percent: Double, resetsAt: Date?) {
        self.title = title
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let limits: [UsageLimit]

    public init(limits: [UsageLimit]) {
        self.limits = limits
    }
}

public enum UsageParserError: Error, Equatable {
    case invalidPayload
    case noLimits
}

public enum UsageParser {
    private struct RawLimit {
        let title: String
        let value: Double
        let resetsAt: Date?
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageParserError.invalidPayload
        }

        var raw: [RawLimit] = []
        if let limit = bucket(root["five_hour"], title: "Session (5-hour)") {
            raw.append(limit)
        }
        let weekly = root["seven_day_oauth_apps"] as? [String: Any] != nil ? "seven_day_oauth_apps" : "seven_day"
        if let limit = bucket(root[weekly], title: "Weekly (7-day)") {
            raw.append(limit)
        }
        raw += scopedLimits(root["limits"])

        guard !raw.isEmpty else { throw UsageParserError.noLimits }

        // The current API sends a `limits` array whose values are named `percent`, so the whole
        // payload is percent-scaled even when every value is below 1 (low usage after a reset).
        // Legacy payloads without it may use fractions; there, any value >= 1 means percent.
        // A legacy payload whose percentages are all below 1 is inherently ambiguous.
        let percentScaled = root["limits"] is [Any] || raw.contains { $0.value >= 1 }
        let scale = percentScaled ? 1.0 : 100.0
        return UsageSnapshot(limits: raw.map {
            UsageLimit(title: $0.title, percent: min(max($0.value * scale, 0), 100), resetsAt: $0.resetsAt)
        })
    }

    private static func bucket(_ node: Any?, title: String) -> RawLimit? {
        guard let object = node as? [String: Any], let value = number(object["utilization"]) else {
            return nil
        }
        return RawLimit(title: title, value: value, resetsAt: date(object["resets_at"]))
    }

    private static func scopedLimits(_ node: Any?) -> [RawLimit] {
        guard let entries = (node as? [Any])?.compactMap({ $0 as? [String: Any] }) else { return [] }
        var seen = Set<String>()
        var result: [RawLimit] = []
        for entry in entries {
            guard
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any],
                let name = [model["display_name"], model["id"]]
                    .compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }),
                let value = number(entry["percent"])
            else { continue }
            let kind = (entry["kind"] as? String ?? "").lowercased()
            guard seen.insert("\(name)\u{0}\(kind)").inserted else { continue }
            let title = windowSuffix(kind).map { "\(name) \($0)" } ?? name
            result.append(RawLimit(title: title, value: value, resetsAt: date(entry["resets_at"])))
        }
        return result
    }

    private static func windowSuffix(_ kind: String) -> String? {
        if kind.contains("month") { return "Monthly" }
        if kind.contains("week") || kind.contains("day") { return "Weekly" }
        if kind.contains("hour") || kind.contains("session") { return "Session" }
        return nil
    }

    /// Accepts numbers and numeric strings (optionally with a trailing "%"); drops negatives and non-finite values.
    private static func number(_ node: Any?) -> Double? {
        let value: Double?
        switch node {
        case let string as String:
            value = Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            value = number.doubleValue
        default:
            value = nil
        }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func date(_ node: Any?) -> Date? {
        guard let string = node as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

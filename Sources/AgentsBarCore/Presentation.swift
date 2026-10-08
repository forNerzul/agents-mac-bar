import Foundation

public enum Severity: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(percent: Double) {
        switch percent {
        case ..<70: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MenuBarSummary: Equatable, Sendable {
    public let title: String
    public let severity: Severity
    /// True when the user has to act (sign in / reopen Claude Code) for limits to show up.
    public let needsAttention: Bool

    public init(title: String, severity: Severity, needsAttention: Bool) {
        self.title = title
        self.severity = severity
        self.needsAttention = needsAttention
    }

    public static func make(state: LimitsState) -> MenuBarSummary {
        switch state {
        case .ok(let snapshot, _):
            // Session and weekly windows are the headline; scoped (per-model) limits are the fallback.
            let headline = snapshot.limits.filter { $0.title.hasPrefix("Session") || $0.title.hasPrefix("Weekly") }
            guard let percent = (headline.isEmpty ? snapshot.limits : headline).map(\.percent).max() else {
                return placeholder(needsAttention: false)
            }
            return MenuBarSummary(
                title: "\(Int(percent.rounded()))%",
                severity: Severity(percent: percent),
                needsAttention: false
            )
        case .expired, .signedOut:
            return placeholder(needsAttention: true)
        case .credentialsUnavailable, .failed:
            return placeholder(needsAttention: false)
        }
    }

    private static func placeholder(needsAttention: Bool) -> MenuBarSummary {
        MenuBarSummary(title: "—", severity: .normal, needsAttention: needsAttention)
    }
}

public enum UsageFormat {
    /// 950 -> "950", 1_234 -> "1.2K", 2_000_000 -> "2M" (one decimal, ".0" dropped).
    public static func compactTokens(_ n: Int) -> String {
        let units: [(suffix: String, size: Double)] = [("K", 1e3), ("M", 1e6), ("B", 1e9)]
        guard n >= 1_000 else { return String(n) }
        var index = 0
        while index < units.count - 1, Double(n) >= units[index + 1].size { index += 1 }
        var value = (Double(n) / units[index].size * 10).rounded() / 10
        // 999_950 rounds to 1000.0K: promote to the next unit.
        if value >= 1_000, index < units.count - 1 {
            index += 1
            value = (Double(n) / units[index].size * 10).rounded() / 10
        }
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return text + units[index].suffix
    }

    /// nil date -> nil; past -> "now"; "45m", "2h 13m", "3d 4h".
    public static func resetCountdown(until date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let minutes = seconds / 60
        if seconds < 3_600 { return "\(minutes)m" }
        let hours = minutes / 60
        if seconds < 86_400 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"; unknown shapes are returned unchanged.
    public static func modelName(_ id: String) -> String {
        var name = id
        if let bracket = name.firstIndex(of: "["), name.hasSuffix("]") { name = String(name[..<bracket]) }
        name = name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 4, parts[0] == "claude",
            !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isLetter }),
            parts[2].allSatisfy(\.isASCII), parts[2].allSatisfy(\.isNumber), !parts[2].isEmpty,
            parts[3].allSatisfy(\.isASCII), parts[3].allSatisfy(\.isNumber), !parts[3].isEmpty
        else { return id }
        return "\(parts[1].capitalized) \(parts[2]).\(parts[3])"
    }

    public static func planName(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

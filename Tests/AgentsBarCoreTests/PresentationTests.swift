import Foundation
import Testing
@testable import AgentsBarCore

@Suite struct UsageFormatTests {
    private static let tokenCases: [(Int, String)] = [
        (0, "0"), (950, "950"), (999, "999"), (1_000, "1K"), (1_234, "1.2K"),
        (2_000_000, "2M"), (12_345_678, "12.3M"), (2_100_000_000, "2.1B"),
    ]

    @Test(arguments: tokenCases)
    func compactTokens(n: Int, expected: String) {
        #expect(UsageFormat.compactTokens(n) == expected)
    }

    @Test func compactTokensRoundsUpAcrossUnitBoundary() {
        #expect(UsageFormat.compactTokens(999_950) == "1M")
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countdownWithoutDateIsNil() {
        #expect(UsageFormat.resetCountdown(until: nil, now: Self.now) == nil)
    }

    private static let countdownCases: [(TimeInterval, String)] = [
        (-60.0, "now"), (0, "now"), (45 * 60, "45m"), (3599, "59m"),
        (2 * 3600 + 13 * 60, "2h 13m"), (24 * 3600 - 1, "23h 59m"),
        (3 * 86400 + 4 * 3600, "3d 4h"), (86400, "1d 0h"),
    ]

    @Test(arguments: countdownCases)
    func countdown(offset: TimeInterval, expected: String) {
        #expect(UsageFormat.resetCountdown(until: Self.now.addingTimeInterval(offset), now: Self.now) == expected)
    }

    private static let modelCases: [(String, String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-5-5[1m]", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929[1m]", "Sonnet 4.5"),
        ("<synthetic>", "<synthetic>"),
        ("gpt-4", "gpt-4"),
        ("claude-opus", "claude-opus"),
    ]

    @Test(arguments: modelCases)
    func modelName(id: String, expected: String) {
        #expect(UsageFormat.modelName(id) == expected)
    }

    @Test func planName() {
        #expect(UsageFormat.planName("max") == "Max")
        #expect(UsageFormat.planName("pro") == "Pro")
        #expect(UsageFormat.planName(nil) == nil)
        #expect(UsageFormat.planName("") == nil)
    }
}

@Suite struct SeverityTests {
    private static let cases: [(Double, Severity)] = [
        (0.0, .normal), (69.9, .normal), (70, .warning), (89.9, .warning), (90, .critical), (100, .critical),
    ]

    @Test(arguments: cases)
    func thresholds(percent: Double, expected: Severity) {
        #expect(Severity(percent: percent) == expected)
    }
}

@Suite struct MenuBarSummaryTests {
    private func snapshot(_ limits: [(String, Double)]) -> UsageSnapshot {
        UsageSnapshot(limits: limits.map { UsageLimit(title: $0.0, percent: $0.1, resetsAt: nil) })
    }

    @Test func usesMaxOfSessionAndWeekly() {
        let state = LimitsState.ok(
            snapshot([("Session (5-hour)", 42), ("Weekly (7-day)", 30), ("Opus Weekly", 95)]), plan: "max")
        #expect(MenuBarSummary.make(state: state) == MenuBarSummary(title: "42%", severity: .normal, needsAttention: false))
    }

    @Test func fallsBackToAllLimitsWithoutSessionOrWeekly() {
        let state = LimitsState.ok(snapshot([("Opus Weekly", 91.6)]), plan: nil)
        #expect(MenuBarSummary.make(state: state) == MenuBarSummary(title: "92%", severity: .critical, needsAttention: false))
    }

    @Test func warningSeverity() {
        let state = LimitsState.ok(snapshot([("Session (5-hour)", 70.4)]), plan: nil)
        let summary = MenuBarSummary.make(state: state)
        #expect(summary.title == "70%")
        #expect(summary.severity == .warning)
    }

    @Test func emptySnapshotIsPlaceholder() {
        let summary = MenuBarSummary.make(state: .ok(UsageSnapshot(limits: []), plan: nil))
        #expect(summary == MenuBarSummary(title: "—", severity: .normal, needsAttention: false))
    }

    @Test(arguments: [LimitsState.expired, .signedOut])
    func attentionStates(state: LimitsState) {
        #expect(MenuBarSummary.make(state: state) == MenuBarSummary(title: "—", severity: .normal, needsAttention: true))
    }

    @Test(arguments: [LimitsState.credentialsUnavailable, .failed(.transport), .failed(.rateLimited(retryAfter: nil))])
    func otherStatesArePlaceholder(state: LimitsState) {
        #expect(MenuBarSummary.make(state: state) == MenuBarSummary(title: "—", severity: .normal, needsAttention: false))
    }
}

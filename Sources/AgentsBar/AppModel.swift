import AgentsBarCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// Omarchy defaults to 900s; the usage endpoint rate-limits, so stay conservative.
    static let refreshInterval: Duration = .seconds(600)

    private(set) var limits: LimitsState?
    private(set) var lastGoodSnapshot: UsageSnapshot?
    private(set) var lastGoodPlan: String?
    private(set) var lastGoodAt: Date?
    private(set) var stats: UsageStats = .empty
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    private let service: LimitsService
    private let scanner: TranscriptScanner

    init(
        service: LimitsService = LimitsService(credentials: CredentialsProvider(), client: UsageClient()),
        scanner: TranscriptScanner = TranscriptScanner(claudeDirectory: TranscriptScanner.defaultClaudeDirectory())
    ) {
        self.service = service
        self.scanner = scanner
    }

    /// State used for the menu bar label: on transient failures the last good limits keep showing.
    var summary: MenuBarSummary {
        guard let limits else { return MenuBarSummary(title: "—", severity: .normal, needsAttention: false) }
        switch limits {
        case .failed, .credentialsUnavailable:
            if let lastGoodSnapshot { return .make(state: .ok(lastGoodSnapshot, plan: lastGoodPlan)) }
        default:
            break
        }
        return .make(state: limits)
    }

    /// Refreshes on launch, then every `refreshInterval` until the task is cancelled.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let service = service
        let scanner = scanner
        async let newLimits = service.load()
        // The scanner does synchronous file IO, so keep it off the cooperative pool and the main actor.
        let newStats = await Task.detached { scanner.scan() }.value
        let state = await newLimits

        // A cancelled load surfaces as a transport error; discard it instead of showing a network failure.
        guard !Task.isCancelled else { return }

        limits = state
        stats = newStats
        lastRefresh = Date()
        if case .ok(let snapshot, let plan) = state {
            lastGoodSnapshot = snapshot
            lastGoodPlan = plan
            lastGoodAt = lastRefresh
        }
    }
}

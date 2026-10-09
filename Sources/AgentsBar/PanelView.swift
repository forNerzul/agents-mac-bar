import AgentsBarCore
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct MenuLabel: View {
    let model: AppModel

    var body: some View {
        let summary = model.summary
        let alert = summary.needsAttention || summary.severity == .critical
        HStack(spacing: 4) {
            Image(systemName: alert ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
            Text(summary.title)
        }
    }
}

struct PanelView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            limitsSection
            Divider()
            statsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Header

    private var plan: String? {
        if case .ok(_, let plan) = model.limits { return UsageFormat.planName(plan) }
        return UsageFormat.planName(model.lastGoodPlan)
    }

    private var header: some View {
        HStack {
            Text("Claude Code").font(.headline)
            if let plan {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: Limits

    @ViewBuilder
    private var limitsSection: some View {
        switch model.limits {
        case nil:
            Text("Loading…").foregroundStyle(.secondary)
        case .ok(let snapshot, _):
            limitRows(snapshot)
        case .some(let state):
            VStack(alignment: .leading, spacing: 8) {
                Text(message(for: state)).font(.callout).foregroundStyle(.secondary)
                if let snapshot = model.lastGoodSnapshot {
                    limitRows(snapshot).opacity(0.5)
                    if let at = model.lastGoodAt {
                        Text("Updated \(Text(at, style: .relative)) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func limitRows(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(snapshot.limits.enumerated()), id: \.offset) { _, limit in
                LimitRow(limit: limit)
            }
        }
    }

    private func message(for state: LimitsState) -> String {
        switch state {
        case .signedOut: "Not signed in. Run `claude` in a terminal to sign in."
        case .expired: "Session expired. Open Claude Code to refresh it."
        case .credentialsUnavailable: "Couldn't read Claude Code credentials from the Keychain."
        case .failed(.rateLimited): "Rate limited by Anthropic. Showing last known limits."
        case .failed(.transport): "Can't reach Anthropic."
        case .failed(.http(let status)): "Usage endpoint error (\(status))."
        case .failed(.unauthorized): "Usage endpoint error (401)."
        case .failed(.parse): "Usage endpoint error (unexpected response)."
        case .ok: ""
        }
    }

    // MARK: Local stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local usage").font(.subheadline.weight(.semibold))
            StatRow(label: "Today", value: UsageFormat.compactTokens(model.stats.today.total))
            StatRow(label: "Last 7 days", value: UsageFormat.compactTokens(model.stats.last7Days.total))
            StatRow(label: "Top model", value: model.stats.topModel7Days.map(UsageFormat.modelName) ?? "—")
            StatRow(label: "Sessions today", value: "\(model.stats.sessionsToday)")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let last = model.lastRefresh {
                Text("Updated \(Text(last, style: .relative)) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not updated yet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r")
                .disabled(model.isRefreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit

    var body: some View {
        let severity = Severity(percent: limit.percent)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.title).font(.callout)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%").font(.callout.monospacedDigit())
            }
            Meter(fraction: limit.percent / 100, color: severity.color)
            if let reset = UsageFormat.resetCountdown(until: limit.resetsAt, now: Date()) {
                Text(reset == "now" ? "Resets now" : "Resets in \(reset)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

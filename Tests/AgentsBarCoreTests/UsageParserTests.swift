import Foundation
import Testing
@testable import AgentsBarCore

private func parse(_ json: String) throws -> UsageSnapshot {
    try UsageParser.parse(Data(json.utf8))
}

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

@Suite struct UsageParserTests {
    @Test func percentScaledPayload() throws {
        let snap = try parse("""
        {"five_hour":{"utilization":37.5,"resets_at":"2026-01-01T10:00:00Z"},
         "seven_day":{"utilization":12,"resets_at":"2026-01-05T00:00:00Z"}}
        """)
        #expect(snap.limits == [
            UsageLimit(title: "Session (5-hour)", percent: 37.5, resetsAt: date("2026-01-01T10:00:00Z")),
            UsageLimit(title: "Weekly (7-day)", percent: 12, resetsAt: date("2026-01-05T00:00:00Z")),
        ])
    }

    @Test func fractionPayloadIsMultipliedBy100() throws {
        let snap = try parse(#"{"five_hour":{"utilization":0.37},"seven_day":{"utilization":0.5}}"#)
        #expect(snap.limits.map(\.percent) == [37, 50])
    }

    @Test func mixedPayloadTreatsOneAsOnePercent() throws {
        let snap = try parse(#"{"five_hour":{"utilization":1.0},"seven_day":{"utilization":0.4}}"#)
        #expect(snap.limits.map(\.percent) == [1, 0.4])
    }

    @Test func lowUsageWithLimitsArrayStaysPercentScaled() throws {
        // Right after a reset every value can be below 1. The current API (which sends `limits`)
        // reports percentages, so 0.5 means 0.5%, not 50%.
        let snap = try parse("""
        {"five_hour":{"utilization":0.5},"seven_day":{"utilization":0.8},
         "limits":[{"kind":"session","percent":0.5},{"kind":"weekly_all","percent":0.8},
                   {"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"Fable"}}}]}
        """)
        #expect(snap.limits.map(\.percent) == [0.5, 0.8, 0])
    }

    @Test func emptyLimitsArrayStillMarksPercentScale() throws {
        let snap = try parse(#"{"five_hour":{"utilization":0.5},"limits":[]}"#)
        #expect(snap.limits.map(\.percent) == [0.5])
    }

    @Test func oauthAppsWeeklyPreferredOverSevenDay() throws {
        let snap = try parse("""
        {"seven_day":{"utilization":10},"seven_day_oauth_apps":{"utilization":20}}
        """)
        #expect(snap.limits.count == 1)
        #expect(snap.limits[0].title == "Weekly (7-day)")
        #expect(snap.limits[0].percent == 20)
    }

    @Test func nullBucketsAreIgnored() throws {
        let snap = try parse("""
        {"five_hour":null,"seven_day_oauth_apps":null,"seven_day":{"utilization":10}}
        """)
        #expect(snap.limits.map(\.title) == ["Weekly (7-day)"])
    }

    @Test func scopedEntryUsesModelNameAndWindow() throws {
        let snap = try parse("""
        {"five_hour":{"utilization":5},
         "limits":[{"kind":"weekly_scoped","percent":42,"resets_at":"2026-01-05T00:00:00Z",
                    "scope":{"model":{"display_name":"Fable","id":"claude-fable"}}}]}
        """)
        #expect(snap.limits.count == 2)
        #expect(snap.limits[1] == UsageLimit(title: "Fable Weekly", percent: 42, resetsAt: date("2026-01-05T00:00:00Z")))
    }

    @Test func scopedEntriesAreDeduplicatedOnNameAndKind() throws {
        let snap = try parse("""
        {"limits":[
          {"kind":"weekly_scoped","percent":42,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"weekly_scoped","percent":43,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"session_scoped","percent":44,"scope":{"model":{"display_name":"Fable"}}}
        ]}
        """)
        #expect(snap.limits.map(\.title) == ["Fable Weekly", "Fable Session"])
        #expect(snap.limits.map(\.percent) == [42, 44])
    }

    @Test func nonObjectScopedEntriesAreSkippedIndividually() throws {
        let snap = try parse("""
        {"limits":[null,"oops",{"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"Fable"}}}]}
        """)
        #expect(snap.limits.map(\.title) == ["Fable Weekly"])
    }

    @Test func scopedEntryFallsBackToModelId() throws {
        let snap = try parse(#"{"limits":[{"kind":"monthly","percent":9,"scope":{"model":{"id":"claude-x"}}}]}"#)
        #expect(snap.limits.map(\.title) == ["claude-x Monthly"])
    }

    @Test func scopedEntryWithoutSuffixKeepsJustName() throws {
        let snap = try parse(#"{"limits":[{"kind":"other","percent":9,"scope":{"model":{"display_name":"Fable"}}}]}"#)
        #expect(snap.limits.map(\.title) == ["Fable"])
    }

    @Test func scopedEntriesWithoutModelOrNameAreSkipped() throws {
        let snap = try parse("""
        {"five_hour":{"utilization":5},"limits":[
          {"kind":"weekly","percent":1,"scope":{}},
          {"kind":"weekly","percent":1},
          {"kind":"weekly","percent":1,"scope":{"model":{"display_name":"","id":""}}}
        ]}
        """)
        #expect(snap.limits.count == 1)
    }

    @Test func resetsAtParsesWithAndWithoutFractionsAndOffsets() throws {
        let snap = try parse("""
        {"five_hour":{"utilization":5,"resets_at":"2026-01-01T10:00:00.123Z"},
         "seven_day":{"utilization":5,"resets_at":"2026-01-01T10:00:00+02:00"},
         "limits":[{"kind":"weekly","percent":5,"resets_at":null,"scope":{"model":{"display_name":"A"}}}]}
        """)
        #expect(snap.limits[0].resetsAt == date("2026-01-01T10:00:00.123Z"))
        #expect(snap.limits[1].resetsAt == date("2026-01-01T08:00:00Z"))
        #expect(snap.limits[2].resetsAt == nil)
    }

    @Test func resetsAtWithMicrosecondsMatchesLiveEndpointShape() throws {
        // Shape observed from the live endpoint (2026-10): six fractional digits and a +00:00 offset.
        let snap = try parse("""
        {"five_hour":{"utilization":49.0,"resets_at":"2026-10-08T21:00:00.829504+00:00"},
         "seven_day":{"utilization":31.0,"resets_at":"2026-10-11T02:00:00.829529+00:00"},
         "seven_day_oauth_apps":null,
         "limits":[{"kind":"session","percent":49},{"kind":"weekly_all","percent":31},
                   {"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"Fable"}}}]}
        """)
        #expect(snap.limits.map(\.title) == ["Session (5-hour)", "Weekly (7-day)", "Fable Weekly"])
        #expect(snap.limits.map(\.percent) == [49, 31, 0])
        let expected = date("2026-10-08T21:00:00Z").timeIntervalSince1970 + 0.829504
        let actual = try #require(snap.limits[0].resetsAt).timeIntervalSince1970
        #expect(abs(actual - expected) < 0.001)
    }

    @Test func missingResetsAtIsNil() throws {
        let snap = try parse(#"{"five_hour":{"utilization":5}}"#)
        #expect(snap.limits[0].resetsAt == nil)
    }

    @Test func stringUtilizationWithPercentSign() throws {
        let snap = try parse(#"{"five_hour":{"utilization":"42%"},"seven_day":{"utilization":"7.5"}}"#)
        #expect(snap.limits.map(\.percent) == [42, 7.5])
    }

    @Test func negativeAndUnparseableValuesAreDropped() throws {
        let snap = try parse(#"{"five_hour":{"utilization":-3},"seven_day":{"utilization":"abc"},"limits":[{"kind":"weekly","percent":8,"scope":{"model":{"display_name":"A"}}}]}"#)
        #expect(snap.limits.map(\.title) == ["A Weekly"])
        #expect(throws: UsageParserError.noLimits) {
            try parse(#"{"five_hour":{"utilization":-3},"seven_day":{"utilization":"abc"}}"#)
        }
    }

    @Test func resultsAreClampedTo100() throws {
        let snap = try parse(#"{"five_hour":{"utilization":250}}"#)
        #expect(snap.limits[0].percent == 100)
    }

    @Test func noLimitsThrows() {
        #expect(throws: UsageParserError.noLimits) { try parse("{}") }
        #expect(throws: UsageParserError.noLimits) { try parse(#"{"five_hour":null,"limits":[]}"#) }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: UsageParserError.invalidPayload) { try parse("not json") }
        #expect(throws: UsageParserError.invalidPayload) { try parse("[1,2]") }
    }
}

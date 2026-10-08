import Foundation
import Testing
@testable import AgentsBarCore

private let asuncion = TimeZone(secondsFromGMT: -3 * 3600)!  // fixed offset, independent of tzdata
private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00Z")!  // 12:00 local

private func makeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = asuncion
    return calendar
}

private func line(
    ts: String,
    session: String = "s1",
    msg: String? = "msg_1",
    model: String = "claude-opus-5-5",
    input: Int? = 10,
    output: Int? = 20,
    cacheWrite: Int? = 30,
    cacheRead: Int? = 40,
    type: String = "assistant",
    uuid: String? = nil,
    requestId: String? = nil
) -> String {
    var usage: [String] = []
    if let input { usage.append("\"input_tokens\":\(input)") }
    if let output { usage.append("\"output_tokens\":\(output)") }
    if let cacheWrite { usage.append("\"cache_creation_input_tokens\":\(cacheWrite)") }
    if let cacheRead { usage.append("\"cache_read_input_tokens\":\(cacheRead)") }
    var message = ["\"model\":\"\(model)\"", "\"usage\":{\(usage.joined(separator: ","))}"]
    if let msg { message.append("\"id\":\"\(msg)\"") }
    var top = ["\"type\":\"\(type)\"", "\"timestamp\":\"\(ts)\"", "\"sessionId\":\"\(session)\""]
    if let uuid { top.append("\"uuid\":\"\(uuid)\"") }
    if let requestId { top.append("\"requestId\":\"\(requestId)\"") }
    top.append("\"message\":{\(message.joined(separator: ","))}")
    return "{\(top.joined(separator: ","))}"
}

private final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ relativePath: String, lines: [String], modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified ?? fixedNow], ofItemAtPath: url.path)
        return url
    }

    func scan() -> UsageStats {
        TranscriptScanner(claudeDirectory: root, calendar: makeCalendar(), now: { fixedNow }).scan()
    }
}

@Suite struct TranscriptScannerTests {
    // 10+20+30+40 = 100 per default line
    private let todayTS = "2026-10-08T14:03:11.123Z"

    @Test func splitsTodayFromLast7DaysUsingLocalDayBoundaries() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, msg: "m1"),
            // 2026-10-08T02:59:59Z is 23:59:59 on Oct 7 local: not today
            line(ts: "2026-10-08T02:59:59Z", msg: "m2"),
            // 2026-10-08T03:00:00Z is 00:00:00 on Oct 8 local: today
            line(ts: "2026-10-08T03:00:00Z", msg: "m3"),
            // Oldest in-window instant: Oct 2 00:00 local = 03:00Z
            line(ts: "2026-10-02T03:00:00Z", msg: "m4"),
            // Just before the window: Oct 1 23:59:59 local
            line(ts: "2026-10-02T02:59:59Z", msg: "m5"),
        ])
        let stats = f.scan()
        #expect(stats.today.total == 200)
        #expect(stats.last7Days.total == 400)
        #expect(stats.today == TokenCounts(input: 20, output: 40, cacheRead: 80, cacheWrite: 60))
    }

    @Test func fileTruncatedMidCharacterStillCountsCompleteLines() throws {
        // A transcript being appended to can end inside a multi-byte UTF-8 sequence.
        let f = try Fixture()
        let url = try f.write("projects/p/a.jsonl", lines: [line(ts: todayTS, msg: "m1")])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"assistant\",\"note\":\"".utf8) + Data([0xE2, 0x82]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: url.path)
        #expect(f.scan().today.total == 100)
    }

    @Test func timestampsWithoutFractionalSecondsAreParsed() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [line(ts: "2026-10-08T14:03:11Z")])
        #expect(f.scan().today.total == 100)
    }

    @Test func entriesOlderThanSevenDaysAreIgnored() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [line(ts: "2026-09-01T10:00:00Z")])
        #expect(f.scan() == .empty)
    }

    @Test func dedupKeepsLargestTotalAcrossFiles() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [line(ts: todayTS, msg: "dup", output: 1)])
        try f.write("projects/q/b.jsonl", lines: [
            line(ts: todayTS, msg: "dup", output: 500),
            line(ts: todayTS, msg: "dup", output: 2),
        ])
        let stats = f.scan()
        #expect(stats.today == TokenCounts(input: 10, output: 500, cacheRead: 40, cacheWrite: 30))
    }

    @Test func fallbackKeyDoesNotCollapseDistinctLines() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, msg: nil, uuid: "u1"),
            line(ts: todayTS, msg: nil, uuid: "u2"),
            line(ts: todayTS, msg: nil, requestId: "r1"),
            line(ts: todayTS, msg: nil),
            line(ts: todayTS, msg: nil),
        ])
        try f.write("projects/p/b.jsonl", lines: [line(ts: todayTS, msg: nil, uuid: "u1")])
        #expect(f.scan().today.total == 600)
    }

    @Test func fallbackKeyCollapsesRepeatedUuidInSameFile() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, msg: nil, output: 1, uuid: "u1"),
            line(ts: todayTS, msg: nil, output: 99, uuid: "u1"),
        ])
        #expect(f.scan().today.output == 99)
    }

    @Test func ignoresSyntheticInvalidNonAssistantAndZeroLines() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, msg: "ok"),
            line(ts: todayTS, msg: "syn", model: "<synthetic>"),
            line(ts: todayTS, msg: "usr", type: "user"),
            line(ts: todayTS, msg: "zero", input: 0, output: 0, cacheWrite: 0, cacheRead: 0),
            line(ts: todayTS, msg: "empty", input: nil, output: nil, cacheWrite: nil, cacheRead: nil),
            "not json at all",
            "",
            #"{"type":"assistant","timestamp":"\#(todayTS)","message":{"id":"nousage","model":"m"}}"#,
            #"{"type":"assistant","timestamp":"garbage","message":{"id":"badts","model":"m","usage":{"input_tokens":5}}}"#,
        ])
        #expect(f.scan().today.total == 100)
    }

    @Test func missingTokenFieldsCountAsZero() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, input: nil, output: 7, cacheWrite: nil, cacheRead: nil)
        ])
        #expect(f.scan().today == TokenCounts(input: 0, output: 7, cacheRead: 0, cacheWrite: 0))
    }

    @Test func recursesIntoSubdirectoriesAndOnlyReadsJsonl() throws {
        let f = try Fixture()
        try f.write("projects/p/deep/er/a.jsonl", lines: [line(ts: todayTS, msg: "a")])
        try f.write("projects/p/notes.txt", lines: [line(ts: todayTS, msg: "b")])
        try f.write("projects/p/data.json", lines: [line(ts: todayTS, msg: "c")])
        try f.write("outside/x.jsonl", lines: [line(ts: todayTS, msg: "d")])
        #expect(f.scan().today.total == 100)
    }

    @Test func fileWithOldModificationDateIsSkipped() throws {
        let f = try Fixture()
        let old = makeCalendar().date(byAdding: .day, value: -8, to: fixedNow)!
        try f.write("projects/p/old.jsonl", lines: [line(ts: todayTS, msg: "stale")], modified: old)
        try f.write("projects/p/new.jsonl", lines: [line(ts: todayTS, msg: "fresh")])
        #expect(f.scan().today.total == 100)
    }

    @Test func sessionsTodayCountsDistinctSessionIdsWithEntryToday() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, session: "s1", msg: "m1"),
            line(ts: todayTS, session: "s1", msg: "m2"),
            line(ts: todayTS, session: "s2", msg: "m3"),
            line(ts: "2026-10-05T12:00:00Z", session: "s3", msg: "m4"),
        ])
        #expect(f.scan().sessionsToday == 2)
    }

    @Test func byModelIsSortedDescendingAndTopModelIsFirst() throws {
        let f = try Fixture()
        try f.write("projects/p/a.jsonl", lines: [
            line(ts: todayTS, msg: "m1", model: "claude-haiku-5-5"),
            line(ts: "2026-10-04T12:00:00Z", msg: "m2", model: "claude-opus-5-5", output: 1000),
            line(ts: todayTS, msg: "m3", model: "claude-sonnet-5-5", output: 200),
            line(ts: todayTS, msg: "m4", model: "claude-opus-5-5"),
        ])
        let stats = f.scan()
        #expect(stats.byModel7Days.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(stats.byModel7Days.first?.tokens.total == 1180)
        #expect(stats.topModel7Days == "claude-opus-5-5")
    }

    @Test func noEntriesMeansNoTopModel() throws {
        let f = try Fixture()
        #expect(f.scan().topModel7Days == nil)
    }

    @Test func missingProjectsDirectoryYieldsEmptyStats() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        let scanner = TranscriptScanner(claudeDirectory: missing, calendar: makeCalendar(), now: { fixedNow })
        #expect(scanner.scan() == .empty)
    }
}

@Suite struct DefaultClaudeDirectoryTests {
    @Test func usesConfigDirWithTildeExpansion() {
        let url = TranscriptScanner.defaultClaudeDirectory(environment: ["CLAUDE_CONFIG_DIR": "~/custom-claude"])
        #expect(url.path == NSString(string: "~/custom-claude").expandingTildeInPath)
    }

    @Test func usesAbsoluteConfigDir() {
        let url = TranscriptScanner.defaultClaudeDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"])
        #expect(url.path == "/tmp/cc")
    }

    @Test func fallsBackToDotClaudeWhenUnsetOrEmpty() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        #expect(TranscriptScanner.defaultClaudeDirectory(environment: [:]).path == expected)
        #expect(TranscriptScanner.defaultClaudeDirectory(environment: ["CLAUDE_CONFIG_DIR": ""]).path == expected)
    }
}

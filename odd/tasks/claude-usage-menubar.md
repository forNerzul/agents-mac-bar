# Feature: claude-usage-menubar

Native macOS menu bar app (SwiftUI `MenuBarExtra`) that shows Claude Code
subscription limits and local usage stats. Inspired by Omarchy's
`omarchy.agents` plugin (omacom/omarchy `shell/plugins/agents` @ b83d3df).

## Scope

- Claude Code only (v1).
- Limits: `GET https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
  Windows: `five_hour` (session), `seven_day_oauth_apps` or `seven_day` (weekly),
  plus model-scoped entries from the `limits` array. Utilization may be a
  fraction (0.37) or a percentage (37.0); a payload with any value >= 1 is
  percent-scaled.
- Token: read-only from the macOS Keychain generic password
  `Claude Code-credentials` (JSON `claudeAiOauth.accessToken`, `expiresAt`,
  `subscriptionType`). Never refresh or write the token.
- Local stats: `~/.claude/projects/**/*.jsonl` (honor `CLAUDE_CONFIG_DIR`),
  assistant `message.usage` tokens, deduplicated by `message.id`.

## Non-goals (v1)

Multiple accounts, autoswitch, other agents, cross-device sync, sign-in flow.

## Architecture

SwiftPM package:
- `AgentsBarCore` (library): models, credentials, usage client, transcript
  scanner. All logic is unit-tested here.
- `AgentsBar` (executable): SwiftUI `MenuBarExtra` UI only.
- `AgentsBarCoreTests`: unit tests with fixtures.

## Tasks

- [x] 1. Scaffold SwiftPM package (Core lib, app executable, tests), .gitignore, README stub
- [x] 2. Usage response parsing (session/weekly/scoped windows, scale normalization)
- [x] 3. Keychain credentials reader (parse, expiry check, no refresh)
- [x] 4. Usage API client (request, 401/429/transport error mapping)
- [x] 5. Local transcript scanner (today/7-day tokens, top model, dedup)
- [x] 6. Menu bar UI (icon with %, panel with meters and resets, refresh timer, 90% alert)
- [ ] 7. App bundle packaging script (LSUIElement) and README

## Evidence

| Task | Commit | Checks |
|---|---|---|
| 1 | 1f112f1 | swift build OK; swift test 1/1 passed (RED n/a: scaffold) |
| 2 | 514067b | RED 17 failing vs stub, GREEN 19/19; extra RED/GREEN for non-object scoped entries; review review-1739f1c216a56b8a approved + acknowledged |
| 3 | fdc7747 | RED 8 failing vs stubs, GREEN 31/31; review review-58f77bdd914bd203 approved + acknowledged |
| 4 | ec540f4 | RED 18 failing vs stubs, GREEN 49/49; review review-ffde107baf041cdc approved + acknowledged |
| 5 | 3d8654e + a3d4791 | RED 7 failing vs stub, GREEN 66/66; review review-230ad0052e42c3d0 approved + acknowledged; follow-up fix for strict UTF-8 (RED total 0, GREEN 67/67), review review-b1eaa46fdc25966a approved + acknowledged, no findings |

## Follow-ups (non-blocking review findings, task 2)

- Weekly fallback: an `seven_day_oauth_apps` object with unusable utilization does not fall back to `seven_day` (UsageParser.swift:44-47).
- Scale heuristic is inherently ambiguous; scoped percents participate in the scale decision (matches Omarchy; revisit if payloads disagree).
- Duplicate scoped titles possible when two kinds map to the same window suffix.
- Fractional-second precision of `resets_at` is not asserted in tests.

## Follow-ups (non-blocking review findings, task 3)

- `expiresAt` unit (epoch milliseconds) is assumed, not verified against the real Keychain item.
- No clock-skew margin in `isExpired`; consider treating tokens expiring within ~60s as expired.
- Boolean `expiresAt` guard is untested.
- First real Keychain read may prompt for access (item owned by Claude Code); `errSecSuccess` with non-Data result is mapped to nil.

## Follow-ups (non-blocking review findings, task 4; locations only, interpretation is the parent's)

- R3-001 UsageClient.swift:48-52: catch-all maps every transport error, including task cancellation, to `.transport`; the UI must not show cancellation as a network failure.
- R3-002 UsageClient.swift:63-64: 403 is folded into `.unauthorized` (shown as expired); a 403 may mean missing scope rather than a stale token.
- R3-003 UsageClient.swift:67-69: HTTP-date `Retry-After` is ignored.
- R3-004 UsageClient.swift:39: request timeout is hard-coded to 10s.

## Follow-ups (non-blocking review findings, task 5)

- R3-strict-utf8-drops-file (TranscriptScanner.swift:92): FIXED in a follow-up commit (lossy decoding).
- R3-dedup-tie-order-dependent (TranscriptScanner.swift:177): equal-total duplicates keep whichever is read first; harmless for totals, may pick a different model/session.
- R3-model-tiebreak-untested (TranscriptScanner.swift:110): alphabetical tiebreak not covered by a test.

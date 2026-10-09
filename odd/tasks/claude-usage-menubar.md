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
- [x] 7. App bundle packaging script (LSUIElement) and README
- [x] 8. Read the token through `/usr/bin/security` instead of SecItemCopyMatching (no recurring Keychain prompts)

## Evidence

| Task | Commit | Checks |
|---|---|---|
| 1 | 1f112f1 | swift build OK; swift test 1/1 passed (RED n/a: scaffold) |
| 2 | 514067b | RED 17 failing vs stub, GREEN 19/19; extra RED/GREEN for non-object scoped entries; review review-1739f1c216a56b8a approved + acknowledged |
| 3 | fdc7747 | RED 8 failing vs stubs, GREEN 31/31; review review-58f77bdd914bd203 approved + acknowledged |
| 4 | ec540f4 | RED 18 failing vs stubs, GREEN 49/49; review review-ffde107baf041cdc approved + acknowledged |
| 5 | 3d8654e + a3d4791 | RED 7 failing vs stub, GREEN 66/66; review review-230ad0052e42c3d0 approved + acknowledged; follow-up fix for strict UTF-8 (RED total 0, GREEN 67/67), review review-b1eaa46fdc25966a approved + acknowledged, no findings |
| 6 | 7fa7956 | RED 46 failing vs stubs, GREEN 81/81 (incl. characterization test from live payload shape: microsecond resets_at); app launched locally (process alive, empty log); live endpoint returned 200 with five_hour 49%, seven_day 31%, Fable weekly 0%; visual check confirmed by user (icon with %, panel with Session/Weekly/Fable Weekly and local stats; macOS Keychain access prompt shown as expected); review review-e20e6082fcb7ba2a approved + acknowledged |
| 7 | 2736bed | RED n/a (packaging/docs); bash -n OK; scripts/build-app.sh built dist/AgentsBar.app; plutil -lint OK; codesign --verify OK; LSUIElement true; version 0.1.0 matches AgentsBarCore.version; dist/ gitignored; `--universal` untested; review review-d34339fa37039bde (high tier, 4 lenses) approved + acknowledged |
| 8 | 94a8bf4 | RED compile failure (missing ProcessRunning/ProcessResult), GREEN 91/91; real `security` exit 44 for missing item confirmed; app relaunched with new binary (user to confirm no prompt across a Claude Code token refresh); review review-eae8b6a08fae35c4 approved + acknowledged |

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

## Follow-ups (non-blocking review findings, task 6; locations only)

- R3-001 AppModel.swift:43-63 (WARNING): refresh loop / in-flight guard; a manual refresh during an in-flight one is dropped silently.
- R3-002 AppModel.swift:31-40 (WARNING): menu bar summary fallback rules for failure states.
- R3-003 PanelView.swift:101 (SUGGESTION).
- Reset countdowns only update when the panel re-renders.

## Follow-ups (non-blocking review findings, task 7; all SUGGESTION unless noted)

- R3-no-bundle-verification (WARNING) build-app.sh:35-56: script does not self-verify the bundle (plutil/codesign --verify) before reporting success.
- R3-developer-id-signing-incomplete / R2-unconditional-no-timestamp / R4-001 build-app.sh:54: Developer ID signing needs hardened runtime + secure timestamp (and notarization) for distribution; `--timestamp=none` is applied unconditionally.
- R2-version-scrape / R3-version-extraction-unvalidated build-app.sh:21-25: version scraped by sed and not validated as non-empty/semver.
- R2-duplicated-build-invocation build-app.sh:27-28; R2-plist-constants build-app.sh:42-47.

## Task 8 rationale (2026-10-09)

Users saw the Keychain password prompt repeatedly. Evidence: item `mdat` changed while the app binary did not; Claude Code 2.1.294 writes the item via `security -i` / `add-generic-password -U` (and has a `delete-generic-password` path), so a per-app "Always Allow" grant on the item is lost whenever Claude Code rewrites it. The item trusts `/usr/bin/security` (its creator), which is how Claude Code reads it back; reading through it does not prompt and does not widen access beyond what Claude Code already allows. Omarchy avoids prompts because Linux Claude Code stores the token in a 0600 file.

## Follow-ups (non-blocking review findings, task 8)

- R3-security-hex-output-unhandled (WARNING) Credentials.swift:143-147: `security -w` prints hex for non-printable payloads; the current ASCII JSON item is unaffected.
- R3-timeout-not-total-bound (WARNING) Credentials.swift:108-112: FIXED together with the CI deadlock below (timeout now bounds read + exit).
- CI failure on 94a8bf4: `readsPayloadLargerThanPipeBuffer` timed out on a 3-core runner. Root cause: stdout reader on `DispatchQueue.global()` starved when the pool was exhausted by parallel blocked tests. Reproduced deterministically (RED) by saturating the global queue; fixed with a dedicated reader thread in 37844fe (GREEN 92/92, 15/15 full-suite stress runs; CI 92/92 green; review review-8f0c1fd30456ff94 approved + acknowledged).
- R3-test-saturates-shared-global-pool (WARNING) CredentialsTests.swift:177-185: the regression test blocks 128 global-queue workers for up to 3s while other suites run in parallel; no other test uses the global queue today.
- R3-abandoned-reader-thread-on-timeout / R3-total-bound-unproved-for-lingering-writer (SUGGESTION): on timeout the reader thread is left to finish after SIGTERM; a grandchild holding stdout could keep it alive.
- R3-blocking-semaphore-wait (SUGGESTION) Credentials.swift:108: the synchronous wait blocks a thread during load.

## Status

Feature v1 complete on branch feat/claude-usage-menubar. Push/PR/merge are the user's decision.

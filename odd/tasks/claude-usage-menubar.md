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

- [ ] 1. Scaffold SwiftPM package (Core lib, app executable, tests), .gitignore, README stub
- [ ] 2. Usage response parsing (session/weekly/scoped windows, scale normalization)
- [ ] 3. Keychain credentials reader (parse, expiry check, no refresh)
- [ ] 4. Usage API client (request, 401/429/transport error mapping)
- [ ] 5. Local transcript scanner (today/7-day tokens, top model, dedup)
- [ ] 6. Menu bar UI (icon with %, panel with meters and resets, refresh timer, 90% alert)
- [ ] 7. App bundle packaging script (LSUIElement) and README

## Evidence

| Task | Commit | Checks |
|---|---|---|

# Agents Bar

A native macOS menu bar app that shows your Claude Code subscription limits and local usage stats.

Inspired by Omarchy's [`omarchy.agents` plugin](https://github.com/omacom/omarchy/tree/master/shell/plugins/agents).

## What it shows

- Session (5-hour) and weekly (7-day) limits, plus model-scoped weekly limits
- Reset countdowns
- Local stats: tokens today and over 7 days, top model, sessions today
- A warning icon at >= 90% usage or when sign-in is needed

## How it works

- **Token**: read-only from the Keychain item `Claude Code-credentials`, via `/usr/bin/security`. The app never refreshes or writes it; when it expires, run Claude Code and it refreshes itself.
- **Limits**: `GET https://api.anthropic.com/api/oauth/usage`. This endpoint is undocumented and may change; if it fails, the app degrades to local stats.
- **Local stats**: scans `~/.claude/projects/**/*.jsonl` (or `$CLAUDE_CONFIG_DIR/projects`), last 7 days, deduplicated by message id.
- **Refresh**: every 10 minutes, plus manual Refresh (⌘R).

### Keychain prompt

The app reads the token by running `/usr/bin/security find-generic-password`, the same way Claude Code does, so macOS does not prompt for your password.

This does not widen access: the item already trusts `/usr/bin/security`, and anything that can run it as you could read the token before. Reading through the Security framework directly would instead prompt again each time Claude Code rewrites the item on token refresh.

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6)
- Claude Code installed and signed in

## Build & run

```sh
swift run AgentsBar          # development
swift test                   # run the tests
scripts/build-app.sh         # build dist/AgentsBar.app
open dist/AgentsBar.app
```

`scripts/build-app.sh` builds natively (arm64 on Apple silicon); pass `--universal` for arm64 + x86_64. It signs ad-hoc unless `CODESIGN_IDENTITY` is set:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

To install, copy `dist/AgentsBar.app` to `/Applications`. To launch at login, add it in System Settings > General > Login Items.

## Project layout

- `Sources/AgentsBarCore`: logic (credentials, usage client/parser, transcript scanner, presentation), unit tested
- `Sources/AgentsBar`: SwiftUI menu bar app
- `Tests/AgentsBarCoreTests`: tests for the core library
- `scripts/build-app.sh`: app bundle packaging

## Limitations (v1)

- Claude Code only
- Single account
- No sync between machines

## Privacy

Nothing leaves your machine except the usage request to Anthropic. The token is never logged.

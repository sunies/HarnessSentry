# Changelog

## 0.4.7

- Expand A3 integration to Continue, iFlow CLI, Kimi Code CLI, Goose, Cline and TRAE using their official JSON, TOML or plugin formats, bringing user-level A3 integrations to 16.
- Add project-scoped OpenCode plugin installation with v1/v2 compatibility and managed-file removal safeguards.
- Add protocol-level assertions for the new integration artifacts and keep WorkBuddy's low-frequency append-only audit bridge as a second A3 signal.

## 0.4.6

- Expand A3 integration to Codex, Claude Code, WorkBuddy, Qoder, ZCode, Cursor, Windsurf, GitHub Copilot CLI, Gemini CLI and Qwen Code, with safe semantic merge, backup and removal for each supported user-level format.
- Add project-scoped Kiro Hook generation and installation without pretending Kiro has a user-global Hook location.
- Add WorkBuddy process recognition and a low-frequency append-only audit bridge that never persists raw commands or replays historical logs.
- Expand the built-in adapter catalog to 21 and the core self-test suite to 15 scenarios.
- Add an isolated ZCode 3.12.3 lab workflow backed by real macOS Endpoint Security notifications through `eslogger`.
- Detect and correlate ZCode `.git/objects` traversal with encrypted checkpoint creation while collapsing high-volume object reads.
- Require an explicit decoy-repository marker and refuse real workspaces; never retain source, prompts, request bodies, environment variables, or raw JSONL.
- Bundle `HarnessSentryLabProbe` with local and Community app builds and document the verified 3.12.3 sample hash and signing identity.

## 0.4.5

- Match the bundled application and notification icon to the blue shield shown in the dashboard sidebar.
- Render the sidebar brand from the exact bundled icon instead of maintaining a separate drawing.

## 0.4.4

- Rework the Settings page into a readable single-column layout with consistent regular-weight labels and smaller supporting text.
- Use compact menu pickers, a bounded content width, and a full-width resource-status line to avoid cramped wrapping.

## 0.4.3

- Add one-click marking of all open incidents as safe, and a confirmed action to clear all incident records while retaining behavior logs.
- Add DeepSeek Harness (`dsh`) process recognition and use verified offline harness artwork where available.
- Scope Git-push and object-storage upload reviews to destination identity, and avoid treating normal read-only developer caches and SDK paths as suspicious.
- Expand the core self-tests to 14 scenarios.

## 0.4.2

- Distinguish normal base monitoring (green), sustained resource throttling (orange), startup (gray), and monitoring failures (red).
- Ignore transient startup CPU samples before changing the resource state.
- Show cached installed-app artwork or custom identifiers for all 19 Harness adapters in the tool list and recent-tools panel.

## 0.4.1

- Enlarged the menu-bar shield to a 20-point drawing with a white outline and code mark.

## 0.4.0

- Aligned the prototype and macOS dashboard with the current compact menu-bar design.
- Retained the code mark and state dot while aligning the menu-bar design with the prototype.
- Added recent incidents, a bounded 12-hour event trend, observed tools, and honest deep-sensor availability in Overview.
- Added a selected-incident detail layout with evidence timeline, facts, and actions.
- Added a structured behavior table and date filter; grouped Settings into detection and privacy panels.
- Added direct incident navigation from the menu popover and fixed incident summaries to show the tool name.

## 0.3.1

- Show notification authorization progress and the failure reason in Settings.
- Add a system-settings shortcut and a test-notification action.
- Open the incident list when a delivered notification is clicked.
- Surface notification delivery errors instead of silently discarding them.

## 0.3.0

- Added safe Codex and Claude Code Hook installation, status detection, backup and removal.
- Added cross-process pause state so the menu app and Hook receiver stop together.
- Added per-event deletion, behavior-log clearing and full local-record clearing.
- Enforced database capacity with evidence-aware cleanup and fixed SQLite upserts.
- Added a low-overhead resource governor with adaptive CLI scan intervals.
- Added an explicitly labelled, opt-in Mock anomaly chain for local validation.
- Added stable Hook event identifiers and more precise upload command classification.
- Added process-backed session identifiers and PID reuse handling.
- Added tag-driven unsigned Community GitHub releases.
- Expanded core self-tests to 11 scenarios.

The Endpoint Security and network system extensions remain optional source
scaffolds until the required Apple entitlements and signing identities are
available. Mock events are never enabled automatically and never perform file or
network I/O.

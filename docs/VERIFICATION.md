# Verification

Environment: macOS 13.7.8, x86_64, Apple Swift 5.8.1, SDK 13.3, Codex CLI 0.155.0-alpha.16.3.

## Automated checks

- Model scaffold compiled, initial three behavioral checks passed.
- JSONL/provider milestone compiled and 16 behavioral checks passed.
- Native application compiled; expanded demo rendered to an actual PNG and visually inspected.
- Core integration suite expanded to 28 passing checks covering lifecycle/plan invariants, explicit user questions, call deduplication, token context, malformed input, task interruption/error, partial writes, truncation, atomic replacement, bounded reads, discovery/staleness, multi-session ordering, hook privacy/symlink protection/merge, completion precedence and real temporary Git worktrees, including suppression of executable Git clean filters. Regression tests also cover copied parent history in subagent rollouts and asynchronous tools that must not imply waiting.
- Dark and light native smoke checks and the live local-session smoke check passed; the installer/helper test verified preservation of existing hooks, idempotence, paths with spaces, metadata filtering and uninstall in temporary directories. Approval channel tests cover inactive/default behavior, heartbeat expiry, request-specific allow/deny/defer outputs and rejection of unrelated response IDs.
- App bundle built with the direct compiler fallback and ad-hoc signed; Info.plist and strict nested signature checked.

`./scripts/test.sh` runs the portable suite. This machine's Command Line Tools do not include XCTest, and its SwiftPM fails while resolving SDK PlatformPath. Therefore **`swift test` could not be run here**. The portable suite compiles/executes the actual production core. The three XCTest model tests remain available for full Xcode installations.

`./scripts/smoke-test.sh` writes machine-readable reports into ignored `build/`, renders dark/light demo screenshots, and runs the helper/installer integration checks against temporary directories. UI checks construct real AppKit windows, native menu items, SwiftUI hierarchies and an NSTouchBar item; they do not mock these classes. The final live check detected 3 independent local sessions with an active working session and no provider diagnostic. It reads existing local rollouts without launching Codex jobs or changing its configuration.

## Manual checks still requiring user hardware/system choices

- Physical Touch Bar rendering, touches and behavior when changing foreground apps.
- Notification permission prompt, banners, sound and Focus behavior. Smoke tests deliberately do not request authorization.
- Launch at Login through an actual logout/login, including macOS approval where required. Smoke tests do not register login items.
- Trust the optional hooks with `/hooks`, then trigger a real Codex approval and, if enabled, review its one-time response. Tests validate their actual helper and configuration merge but do not change the user's hook trust.
- Developer ID signing, notarization and other Mac/CPU/OS configurations.

## Repeatable manual interaction

1. Launch the `.app`; select Demo Mode and expand the Floating Bar.
2. Drag its sparkle, collapse/expand, toggle pin, switch appearance, close/show through the menu.
3. Wait through the demo's approval and completed phases. Completion auto-hides after the configured delay.
4. End Demo Mode and start a local Codex task. Switch sessions from the menu. With no `update_plan`, verify that no completion percentage appears.
5. Open a Git project and compare displayed worktree totals with `git diff --numstat HEAD` and `git status --porcelain`.

# Codex Touch Bar — architecture

## Research before implementation (2026-09-29)

The reference [Claude-TouchBar](https://github.com/dawiddrzewiecki/Claude-TouchBar), inspected at `3043dff3f53082836a3dd73ba6f543cf39a004ce`, uses a small Swift hook executable, atomic local state, FSEvents/Darwin notifications, a session reducer, AppKit status menu and floating NSPanel. Its timer and in-flight tool tracking are event driven. Its global Touch Bar uses private DFRFoundation APIs. We implement independently, using public AppKit APIs only. We do not copy Claude hook names, status-line fields, private Touch Bar APIs, or inferred usage-window progress.

Official Codex source inspected at `8ffd91e42aa001b7e897bea812b02f89264f9fa0`; installed CLI `0.155.0-alpha.16.3`. Sources:

- [App Server protocol](https://learn.chatgpt.com/docs/app-server): JSON-RPC turn/item/plan/token events and approval requests are available to the client owning that server. Starting another server does **not** subscribe to another CLI's live approvals.
- [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode): `codex exec --json` emits structured events for a process the caller starts; it is not a global event bus.
- [Hooks](https://learn.chatgpt.com/docs/hooks): supported versions expose lifecycle hooks including PermissionRequest, PreToolUse and PostToolUse. User hooks need review/trust in Codex. The app never bypasses this.
- [Rollout persistence policy](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/rollout/src/policy.rs): task markers, metadata, token counts and response items persist. Approval requests, transient errors and plan-update events generally do not. `update_plan` tool arguments can provide an actual structured plan.

## Integration decision

The default provider reads existing local `$CODEX_HOME/sessions/**/*.jsonl` (default `~/.codex`) without editing them, launching agent tasks or reading credentials. JSONL is an internal, version-sensitive fallback, isolated behind a tolerant parser and fixtures. It incrementally reads complete lines, handles partial writes, file replacement/truncation, unknown events and multiple sessions. The local CLI/IDE/desktop must actually persist rollouts there; remote-only sessions are unavailable.

An optional, separately installed hook helper writes allowlisted lifecycle metadata into a private application-support directory. In default observer mode it returns `{}` immediately: no approval decisions, prompts, command execution, stdin injection, automation privileges or server sockets. Optional approval review is described below. PermissionRequest establishes WAITING; observable continuation clears it. Hook availability and exact meaning depend on the installed Codex version. The helper ignores subagent Stop events when their transcript identity differs from the parent session. Stop is a stop **attempt**, not proof of completion because another hook may continue the turn; rollout task_complete remains authoritative.

## Optional documented approval responses

An opt-in setting plus reinstall/trust of the PermissionRequest hook enables review responses. `ApprovalStore` uses private local, UUID-bound request/reply files and a recent app heartbeat. The helper waits at most 120 seconds (hook timeout 125), returns only the documented allow/deny shape after an explicit reviewed decision, and otherwise returns `{}` to continue Codex's normal approval flow. There is no automatic or persistent grant. The review dialog displays complete tool input and cwd; its default action defers to Codex. A Touch Bar button opens the same review. Observer metadata still excludes tool input; full input exists only in temporary approval records. Expired/replaced request IDs cannot receive a UI response. A dead app, missing heartbeat or timeout never grants permission.

## Truth and derived data

| Value | Source / interpretation |
|---|---|
| Task start/end, thread/turn IDs | Persisted Codex markers, when present |
| Current tool/command | Structured response call / optional hook metadata; latest observed, not a full live debugger |
| Plan/stages | Actual `update_plan` arguments; never parse a prose promise into a fake plan |
| Percentage | Completed plan entries divided by all entries; measures steps, not time or overall project completion |
| Waiting for approval | Optional PermissionRequest hook; no inactivity heuristic |
| Waiting for user input | Explicit request_user_input call when persisted; never infer from arbitrary message text |
| Errors | Explicit observed errors / failed tool results; not all errors are persisted |
| Duration | Local elapsed time between Codex timestamps, including waiting |
| Model / context / usage | Only explicit fields; context ratio uses last context usage and reported window, not cumulative tokens |
| Git branch, changed files, +/- | Read-only Git worktree snapshot; includes the user's and other tools' edits and is labeled accordingly |
| Usage limits | Only explicit Codex token_count rate_limits; optional, potentially stale snapshots |
| Missing final marker | Activity becomes unconfirmed; never claim success or approval from silence |

## Modules and data flow

```text
Codex rollouts ── incremental JSONL ─┐
Optional hooks ── private metadata ─┤
                                   ▼
                      AgentProvider → CodexProvider
                                   ▼
                   session reducer → ProviderSnapshot
                                   ▼
             SessionManager (main-thread published state)
              ├── GitMonitor (background, selected worktree)
              ├── NotificationManager (live transitions only)
              ├── Menu Bar (NSStatusItem)
              ├── Floating Bar (NSPanel + SwiftUI)
              └── Touch Bar (public NSTouchBar + hosting view)
```

`CodexTouchBarCore` contains testable Foundation models, parsing and monitoring. `CodexTouchBar` owns native views, windows, preferences, notifications and login registration. `CodexTouchBarHook` is a small synchronous helper. `AgentProvider` allows future provider implementations without coupling views to Codex payloads. Demo uses the same session models, is prominently labeled, and never modifies real session state.

The session selector prioritizes a newly waiting session, then active work. Manual session selection persists until another session explicitly requires attention. Notifications suppress initial history replay and duplicate transitions. A serial utility queue performs filesystem and Git work; UI changes arrive on the main queue. No network services or third-party runtime dependencies.

## Native presentation

macOS 13+, Swift 5.8+, SwiftUI and AppKit. Floating panel supports drag, expansion, collapse, topmost preference, appearance preference, auto-show and delayed auto-hide. Public NSTouchBar works while an app window is active; macOS controls availability and no global Control Strip takeover is attempted. On hardware without Touch Bar all other features work. Notifications use UNUserNotificationCenter and launch-at-login uses SMAppService.

## Verification gates

1. Compile package skeleton and model tests.
2. Compile and test real parsers/provider, lifecycle, partial writes and truthful progress.
3. Compile native presentation and run all tests.
4. Build an `.app`, validate bundle/signature, run demo and live smoke tests, and capture native rendered screenshots.

Physical Touch Bar and notification presentation under Focus require user hardware/session checks. Signing for public distribution requires a Developer ID and notarization; the build script can ad-hoc sign local builds.

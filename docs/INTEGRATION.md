# Codex integration research

Inspected 2026-09-29. Official source commit: `8ffd91e42aa001b7e897bea812b02f89264f9fa0`. Local CLI: `0.155.0-alpha.16.3`; `codex features list` reported lifecycle hooks enabled/stable. There is no claim of support for every past/future release.

## Available interfaces

- [App Server](https://learn.chatgpt.com/docs/app-server): client-owned JSON-RPC stream with turn/item status, plan updates, diffs, token updates and approval requests. Appropriate for an app that runs its own Codex sessions; a separately spawned server does not observe another CLI's runtime.
- [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode): `codex exec --json` emits a structured stdout stream for that invocation. This app does not start jobs or claim it is a global session feed.
- [Hooks](https://learn.chatgpt.com/docs/hooks): version-dependent lifecycle instrumentation, with explicit trust review. We use no Claude-only Notification/statusLine hooks. Default observation returns no decision; optional reviewed PermissionRequest responses use the documented hook output.
- Local rollout files: passive fallback chosen for existing sessions. Format changes remain a compatibility risk.

## Pinned source audit

| Source | Evidence used |
|---|---|
| [Persistence policy](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/rollout/src/policy.rs) | Lifecycle/token/raw response items persist; approval, transient execution/error and PlanUpdate events generally do not |
| [Protocol](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/protocol/src/protocol.rs) | Session metadata, task markers, token/rate-limit fields |
| [Response items](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/protocol/src/models.rs) | Call/output correlation, function and custom tools |
| [Plan tool](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/protocol/src/plan_tool.rs) | Structured entries and pending/in_progress/completed states |
| [Hook schemas](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/hooks/src/schema.rs) | Common hook fields and per-event input schemas |
| [PermissionRequest](https://github.com/openai/codex/blob/8ffd91e42aa001b7e897bea812b02f89264f9fa0/codex-rs/hooks/src/events/permission_request.rs) | Hook precedes either automatic review or human approval; not proof of a visible prompt |

## Implemented fallback schema

Envelope: `{"timestamp":"ISO-8601","type":"...","payload":{...}}`.

- `session_meta`: `id`, `cwd`, `timestamp`, optional `git.branch`, `source`, `context_window`.
- `turn_context`: latest `model` and `cwd`.
- `event_msg`: `task_started`/`turn_started`, `task_complete`/`turn_complete`, `turn_aborted`, `token_count`, legacy successful `patch_apply_end`, explicit error if present.
- `response_item`: `function_call`, `custom_tool_call`, paired outputs; `name`, `call_id`, JSON-string `arguments` or freeform `input`.
- `update_plan`: actual JSON entries; unknown status or malformed plans are rejected as a unit.
- `request_user_input`: pending by call ID until its output. Arbitrary question marks in assistant text are not parsed as waiting.
- `token_count.info.last_token_usage.total_tokens / model_context_window`: raw context estimate. `total_token_usage` is cumulative and is not used as occupancy. Codex's own UI may reserve a baseline and therefore show a different percentage.
- `rate_limits.primary/secondary`: optional `used_percent`, `window_minutes`, `resets_at`. Windows are not assumed to be hourly/weekly.

The app does not parse encrypted reasoning, credentials or browser content. Command previews come only from explicit structured arguments, never shell execution. Executed shell edits outside persisted patch events cannot reliably be attributed to Codex; Git totals remain whole-worktree statistics.

## Observer lifecycle

In observer mode the helper returns `{}` even on malformed input or write failures; no approval or continuation fields. It allows only lifecycle names, IDs, model, working directory, transcript path and tool name. Input is bounded to 2 MiB, file writes are nonblocking/locked, regular-file-only and private. Hook files rotate at 2 MiB; retained metadata is best effort. Subagent events with mismatching rollout transcript identity are ignored to protect parent state. Anonymous transcript formats cannot guarantee parent/subagent disambiguation.

The monitor merges hook freshness with meaningful rollout activity; token-count updates alone cannot clear an approval indication. Recorded completion wins over a late Stop hook. A later explicit new turn reopens state. Missing telemetry eventually changes the presentation to unconfirmed, with no invented success.

## Reference project

Claude-TouchBar inspected at `3043dff3f53082836a3dd73ba6f543cf39a004ce`: README, ARCHITECTURE, cctb helper, Store, ClaudeMonitor, HookProcessor, Requests, TouchBarPresenter, PreviewPanel and AppController.

Transferable patterns: isolated helper, per-session state, timestamp-based timer, native floating panel, menu lifecycle and login service. Not transferred: Claude schemas, Claude approval transport, estimated limits, private DFRFoundation/global Touch Bar methods. Our implementation adds actual structured stage progress and native notifications.

## Optional review transport

The documented PermissionRequest response permits `hookSpecificOutput.hookEventName = "PermissionRequest"` and `decision.behavior = "allow" | "deny"`. Deny may include `message`; no extra policy, updatedInput or permissions fields are sent. Codex combines hooks conservatively: another deny still wins. The implementation enables this only with both the app setting and an explicitly installed `--approval-ui` hook command. Review buttons bind to the exact live UUID, immutable payload and expiry; timeout, app loss, invalid input or Continue in Codex produces `{}`. It requires no private API or synthetic keyboard input.

# Real-world E2E log — daybreak-autoreply plugin (2026-11-24)

Production verification against the partner's real sessions (no sandbox).

## Dev install (CLI, no TUI)

- `/plugins` empty with a local marketplace → cause: local marketplaces require a root manifest. Created `.agents/plugins/marketplace.json` (schema copied from `openai-bundled`).
- `codex plugin add daybreak-autoreply@daybreak-dev` → cache at `~/.codex/plugins/cache/daybreak-dev/daybreak-autoreply/0.1.0` + a `[plugins."daybreak-autoreply@daybreak-dev"]` entry in config.toml.

## Engine v1 (SendKeys)

- Daemon started by simulating the hook (env `CLAUDE_PLUGIN_ROOT/DATA` + `ensure-daemon.ps1`).
- 2 real sends verified: `AUTORESPOND … 19:50:03` and `19:51:10` (foreground=WindowsTerminal).
- Partner feedback: the 60 s / 3-per-10-min cooldown+burst suppressed their block→retry loop; keys went to the focused window, not the blocked session.

## Engine v2 (codex queue) — verified end to end

- Real `QUEUE_SENT`: 19:58:31, 19:58:46, 19:58:55 (threads 01a208d7… and 01a20ec8…), with the message id returned by codex.
- Delivery confirmed INSIDE the target rollout: `/goal resume` items appear in `rollout-…01a208d7-fd7f…jsonl` at 18:58:59–18:59:16Z (19:58–19:59 local), right after the QUEUE_SENTs.
- Subagents reject queuing (-32600) and the engine skips to the next UUID in the filename — observed and handled.
- `--resume` warned "start a local daemon" (logged warning, not a failure): with the TUI open, delivery happens anyway. (--resume was later removed entirely after a tab-focus-stealing report.)

## Rate and text (partner requests)

- cooldown 5 s + a 50/10-min valve initially; then 0/0 (unlimited) at the partner's explicit request (MATCH→QUEUE_SENT on every block, suppression only inside the window).
- Reply text changed to `continua` (send_text + cyber_policy + usage_limit_exceeded; `/compact` kept for context_window_exceeded). Later: factory default `continue`, the partner keeps `continua` locally, and `/daybreak-set <text>` changes it live.

## Incident 20:03-20:08

With cooldown/burst at 0, SUBAGENT rollouts (single-UUID, rejected by `codex queue` with -32600) fell back to SendKeys 51 times → `continua` typed into unrelated windows/tabs (including another of the partner's sessions). Fixes: `sendkeys_fallback=false` by default (queue mode NEVER types outside the session), queue without `--resume`, per-thread loop breaker. The partner later disabled the breaker locally (`per_thread_max=0`) after it paused their fast-looping session — their explicit choice, documented in the README.

## Still pending from the partner (does not block operation)

- Trusting the plugin's SessionStart hook via `/hooks` in a new session → autostart after machine reboots (the live daemon already survives everything else: spike verdict A).

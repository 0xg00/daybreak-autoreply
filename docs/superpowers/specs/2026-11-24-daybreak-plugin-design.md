# Daybreak Autoreply — Codex Plugin (Design)

**Date:** 2026-11-24
**Status:** approved
**Supersedes:** `2026-11-23-daybreak-watchdog-design.md` as product vision (the PowerShell watchdog remains the internal engine; its spec still governs engine behavior).

## Intent

When Codex CLI kills a turn through the cybersecurity policy (`codex_error_info: "cyber_policy"` — the "apply for Daybreak" block), the plugin automatically sends the user-configured text (originally `/goal resume`, factory default `continue`) into the session where Codex runs. No human interaction, always. The reply is configurable per error code.

Packaging is a **Codex plugin** (`.claude-plugin` format) so installing, enabling and distributing it on GitHub is trivial and visual (`/plugins` → Enter).

## Why

- The partner works in security and hits the block daily (real census from their machine: 3,277 `usage_limit_exceeded`, 3,013 `cyber_policy`, 3 `context_window_exceeded`). Their manual loop: block → dead session → `/resume` → message → instant block.
- They want the watchdog's auto-responder **as a plugin**: easy for anyone to install and publishable on GitHub.

## Empirical evidence that fixed the architecture (spike 2026-11-24)

A log-only hook installed in `~/.codex/hooks.json` during a real workday:

| Event | Fires? | Evidence |
|---|---|---|
| `SessionStart` (startup and resume) | Yes | 17:47:25 (`src=resume`), 17:52:13 (`src=startup`), with `session_id` and `transcript_path` |
| `Stop` on a normal turn | Yes | 17:52:24, with `last_assistant_message` |
| `Stop` on a turn killed by `cyber_policy` | **NO** | 17:42:43 and 17:49:33 — zero deliveries to the hook |

Conclusion: the 100 % native path (`Stop` → `decision:"block"` → injected prompt) is discarded by evidence. Synthetic keyboard injection (the already-validated watchdog engine) remained necessary at that point.

Operational lesson from the spike: Windows hook commands must avoid leading quoted paths with spaces (broken spawn). The working pattern: `cmd /c` + 8.3 path (`C:\PROGRA~1\POWERS~1\7\pwsh.exe`) or variables like `${CLAUDE_PLUGIN_ROOT}` with space-free paths. The official `codex@openai-codex` plugin uses `${CLAUDE_PLUGIN_ROOT}/scripts/...` on this very machine and works.

## Goals

1. **Core intact**: every watched block (default: the three census codes — `cyber_policy`, `usage_limit_exceeded`, `context_window_exceeded`) → automatic send of the configured text per code. Detection within ≤ ~2 s of the event.
2. 3-step install for any Windows user with Codex CLI: declare marketplace → `/plugins` → Install. No manual steps afterwards: the `SessionStart` hook starts the engine on its own.
3. Visual control inside Codex: `/daybreak-status`, `/daybreak-test`, `/daybreak-stop`, `/daybreak-start`.
4. Single GitHub repo = installable plugin + code + tests + README.
5. Editable config (`config.json` in the plugin data dir): code→text map, cooldown, burst, terminals.

## Non-goals

- macOS/Linux (the engine uses SendKeys/CIM/Win32 — Windows only, declared in the README).
- Graphical UI outside Codex (web dashboard, tray icon). "Visual" = `/plugins` browsing + slash commands.
- Instant post-`/resume` trigger (refinement C, deferred).
- Modifying anything under `~/.codex/` except the plugin's own files (plugin cache, `plugin-data`, marketplace/plugin entries managed by Codex).

## Anti-goals

- The user having to touch the keyboard after a block for the reply to go out (if it happens, it's a failure, not a limit).
- Losing the already-tested watchdog behavior (36 green asserts) in the packaging.

## Architecture (approach A — hybrid with embedded engine)

```
GitHub repo (daybreak-autoreply)/
├── .claude-plugin/plugin.json        # manifest: name, version, description
├── hooks/hooks.json                  # SessionStart → scripts/ensure-daemon.ps1
├── scripts/
│   ├── watch.ps1                     # engine (parametrized)
│   ├── ensure-daemon.ps1             # starts the engine if not running; cleans up after updates
│   └── stop.ps1                      # clean stop
├── commands/
│   ├── daybreak-status.md            # status, uptime, last sends
│   ├── daybreak-test.md              # sandbox DRYRUN with a synthetic event
│   ├── daybreak-stop.md              # persistent off (disabled flag)
│   └── daybreak-start.md             # re-enable (clears flag)
├── tests/                            # existing + new suites (paths adapted)
├── config.json                       # default config (copied to PLUGIN_DATA on first run)
└── README.md                         # what it is, install, config, limits
```

### Flow

1. The user declares the git marketplace and does `/plugins` → Install.
2. Codex trusts the plugin's hooks via `/hooks` (standard one-time trust flow).
3. On every `SessionStart` (startup or resume), `ensure-daemon.ps1` checks a state file in `PLUGIN_DATA` (PID + script path). If the live process doesn't exist or the path changed (plugin update), it launches `watch.ps1` detached (`-WindowStyle Hidden`) with `-ConfigPath` pointing at `PLUGIN_DATA/config.json`. First run: copies the default `config.json` there and creates the logs dir.
4. `watch.ps1` (engine, behavior identical to the watchdog): 1 s rollout polling, structural JSON-parse detection (`payload.error.codex_error_info`), foreground-safe gates, clipboard backup/restore + SendKeys, cooldown + burst + pause. Logs to `PLUGIN_DATA/logs/watchdog.log`.
5. Real block → the engine sends the text from the `responses` map.

### Design calls

- **Active by default**: `dry_run=false` in the default config (the partner's explicit requirement: "just send what I want"). The README warns third parties in bold.
- **Data outside the cache**: config, logs and state live in `PLUGIN_DATA` (`~/.codex/plugin-data/...`), never in the plugin root (the cache is replaced on every update).
- **Hook paths without leading quotes**: the `${CLAUDE_PLUGIN_ROOT}` pattern (no spaces) — lesson from the spike.
- **Hook commands**: `type:"command"`, short `timeout` (10 s) for `SessionStart`; the daemon launches detached and the hook returns immediately.
- **Name**: `daybreak-autoreply` (plugin and repo). Initial version 0.1.0.
- Slash commands are prompt `.md` files: status reads the state file/log and shows it; stop/start only touch the `disabled` flag in `PLUGIN_DATA` (and stop the process if running); test runs the sandbox harness. No mutations outside `PLUGIN_DATA`.

## Constraints

- PowerShell 7+, no external modules (same as the watchdog).
- Never write to `~/.codex/sessions/` (read-only).
- UTF-8 without BOM everywhere.
- Tests remain hand-rolled assert scripts (no Pester) + E2E in an isolated sandbox.

## Known risks (inherited from the watchdog, documented)

- Multi-tab Windows Terminal (sendkeys mode): SendKeys goes to the focused window.
- Collision with user typing during the paste (~500 ms window).
- Native toasts require PS 7.4+ (best-effort, wrapped in try/catch).
- The engine depends on Codex internals (`~/.codex/sessions/**/rollout-*.jsonl` and the `codex queue` CLI): if OpenAI changes them, the plugin needs an update (accepted risk).

## Builder check questions and their resolutions

The independent check (2026-11-24) raised 6 points; none remain open:

1. **Does a daemon spawned by the hook survive the hook exiting?** (architecture linchpin). **Resolution: pre-build spike (Task 0)** — heartbeat child; survival verified after the hook exits and the session closes. Verdict A (it survives); had it not, the launch mechanism would have changed (scheduled task) before building the rest.
2. **Single-repo marketplace layout?** **Resolved by local evidence**: `sol-advisor` is a single git repo installed as its own marketplace, with the plugin manifest at the repo root. Our repo replicates that pattern with `.claude-plugin/plugin.json` (plus, for local marketplaces, a root `.agents/plugins/marketplace.json` manifest — discovered during dev-install).
3. **Which codes and timings by default?** **Resolved by approved spec + census**: the three codes with the watchdog's `responses` map. Timing goal restated: detection ≤ ~2 s.
4. **What does `/daybreak-test` exercise?** **Call**: `e2e-dryrun.ps1`-style sandbox — an isolated engine instance with a synthetic rollout in temp, forced `dry_run`. It never touches the live daemon or sends real messages.
5. **Is `/daybreak-stop` temporary or persistent?** **Call**: persistent — writes a `disabled` flag in `PLUGIN_DATA` that `ensure-daemon.ps1` respects; `/daybreak-start` clears it.
6. **Hook trust after an update?** **Resolved by official docs**: trust is recorded per hash → changed hooks go into review and are skipped with a startup warning until re-trusted via `/hooks`. Documented in the README's update section; ensure-daemon's "path changed" cleanup covers the orphaned old daemon.

## v0.2 addendum (2026-11-24, after real E2E): `codex queue` delivery

Partner feedback with the daemon in production: (a) cooldown/burst suppressed replies for their dying session that blocks every few seconds — they want a reply ALWAYS; (b) SendKeys goes to the focused window — they multitask and want the reply to reach THE blocked session, not whatever is in front.

The discovery that solves it: `codex queue --thread <UUID> --message <text>` injects the message into the exact session, with no keyboard, focus or windows (validated live: message queued into thread 01a209a6). Observed failure: unloaded subagent UUIDs → code -32600; solved by trying every UUID in the rollout filename until one is accepted.

Changes on top of the design:
- New config key `delivery`: `"queue"` (new default) | `"sendkeys"` (legacy, with its foreground gates).
- Queue mode: MATCH → extract UUIDs from the rollout name → try `codex queue` with each (first exit 0 wins; logged) → if all fail, legacy SendKeys fallback (later disabled by default — see incident below).
- `require_terminal_foreground`, `terminals` and `foreground_wait_s` only apply to sendkeys mode.

## Post-release adjustments (same day, partner-driven)

- Reply text changed from `/goal resume` to `continua` for the partner; factory default is `continue`. `/daybreak-set <text>` changes it live (config hot-reload in the daemon loop).
- Rate limits removed at the partner's request: `cooldown_s=0`, `max_burst=0` (0 = unlimited; blocks landing inside the delay window are still sent).
- Incident (20:03-20:08): subagent rollouts (single-UUID, rejected by `codex queue` with -32600) fell back to SendKeys 51 times → `continua` typed into unrelated windows/tabs. Fixes: `sendkeys_fallback=false` by default (queue mode never touches the keyboard), queue called without `--resume` (it stole tab focus), and a per-thread loop breaker (`per_thread_max=3` per 5 min, 15 min pause; `0` = off — the partner runs with it off).
- Final-review fixes (opus reviewer): no absolute `sessions_dir` in the default config (portability), quoted spawn arguments (profiles with spaces), identity-checked kills (no Stop-Process onto PID-reused innocent processes), an anti-duplicate mutex for concurrent SessionStart, and warnings for unknown config keys.

## What's left for the builder

- Move/adapt `watch.ps1`, `stop.ps1` and tests to the plugin layout (parameterized paths, no hardcoded repo paths).
- `ensure-daemon.ps1` with a state file (PID + path + post-update cleanup).
- Manifest, hooks.json, commands, marketplace install README.
- Keep the suites 100 % green; final manual E2E on the partner's real "dying session".

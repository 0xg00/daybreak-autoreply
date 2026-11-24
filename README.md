# daybreak-autoreply

Codex CLI plugin that **auto-replies to cybersecurity policy blocks** (the infamous "This content can't be shown… apply for Daybreak" wall). When a turn dies with `cyber_policy` or `usage_limit_exceeded`, the plugin injects your text — `continue` by default — into **that exact session**. No keystrokes, no focus stealing, works while you're in any other app or tab.

**Windows-only** (the engine uses CIM, with an optional SendKeys fallback).

## Install

```
codex plugin marketplace add https://github.com/YOUR-USER/daybreak-autoreply.git
codex plugin add daybreak-autoreply
```

Then: `/hooks` → trust the plugin's `SessionStart` hook (once — Codex reminds you at startup if pending) → open a new session. The hook starts the watchdog daemon on its own. There is no step 4.

For local development: `codex plugin marketplace add <absolute path to this repo>` instead of the git URL.

> ⚠️ **Active by default**: `dry_run=false`. Install + open a session = the watchdog is armed and will send the real reply on the next block. To try it safely first, run `/daybreak-test` (isolated sandbox, no real messages) or set `"dry_run": true` in your config.

## How it works

1. Detects blocks by reading session rollouts (`~/.codex/sessions/**/rollout-*.jsonl`, read-only) — the structural `payload.error.codex_error_info` field, never loose text. Detection latency: ~1-2 s.
2. Injects your text into **the exact blocked session** with `codex queue --thread <uuid> --message <text>`: no keyboard, no focus stealing, works with Codex in any tab and you in any application. Subagent UUIDs that reject queuing are skipped automatically.
3. No rate limits by default: every block gets its reply (cooldown and burst at `0` = unlimited). The only valve: one SAME session in a tight loop (block→continue→block) is paused for 15 min after 3 replies in 5 min (`per_thread_max: 0` removes it).

Default reply map (change it with `/daybreak-set`):

| code | reply |
|---|---|
| `cyber_policy` | `continue` |
| `usage_limit_exceeded` | `continue` |
| `context_window_exceeded` | `/compact` |

## Slash commands

| command | what it does |
|---|---|
| `/daybreak-set <text>` | change the reply text — hot-reloaded, no restart |
| `/daybreak-status` | PID, uptime, config, last 5 events |
| `/daybreak-test` | sandbox E2E (DRYRUN, no real messages) |
| `/daybreak-stop` | persistent off (survives sessions) |
| `/daybreak-start` | re-enable and start |

## Configuration

Lives at `~/.codex/plugin-data/daybreak-autoreply/config.json` (created on first run; hot-reloaded every few seconds — edit and it just applies).

| key | default | meaning |
|---|---|---|
| `sessions_dir` | `~/.codex/sessions` | where to watch rollouts |
| `responses` | map above | code → text to send |
| `watch_codes` | all three | codes that trigger |
| `send_text` | `continue` | fallback if the code isn't in `responses` |
| `delivery` | `queue` | `queue` = inject into the exact session via `codex queue`; `sendkeys` = legacy keyboard mode with foreground gates |
| `sendkeys_fallback` | `false` | if `queue` fails, never touch the keyboard (set `true` to enable legacy fallback) |
| `per_thread_max` / `per_thread_window_min` / `per_thread_pause_min` | `3` / `5` / `15` | per-session loop breaker (`0` = off) |
| `delay_s` | `3` | wait after detection (blocks landing inside the window are still sent) |
| `cooldown_s` | `0` | minimum between replies (`0` = none) |
| `max_burst` / `burst_window_min` | `0` / `10` | `0` = unlimited (optional anti-runaway valve) |
| `pause_after_limit_min` | `15` | pause after exhausting the burst valve |
| `require_terminal_foreground` | `true` | sendkeys mode only: never type unless focus is a terminal |
| `terminals` | 9 processes | sendkeys mode only: valid terminal processes |
| `foreground_wait_s` | `120` | sendkeys mode only: max wait for terminal focus |
| `dry_run` | `false` | `true` = log only, send nothing |
| `log_file` | `logs/watchdog.log` | relative to the plugin data dir |

## Updating

`/plugins` → reinstall/update. The hook changes hash → `/hooks` → re-trust (Codex warns at startup). An old daemon from a previous cache path is detected and replaced automatically (route-based cleanup in `state.json`).

## Known limits

- Reply delivery depends on Codex CLI internals (`codex queue`, rollout format). If OpenAI changes them, the plugin needs an update.
- The per-session loop breaker exists because an unattended block→continue loop burns quota; tune it to taste.
- Toasts require PowerShell 7.4+ (best-effort; everything else works without them).

## Development

```
pwsh -File tests/run-tests.ps1             # 76 unit asserts
pwsh -File tests/e2e-plugin.ps1            # plugin integration E2E (sandbox)
pwsh -File tests/e2e-dryrun.ps1            # sendkeys engine E2E (sandbox)
pwsh -File tests/test-plugin-structure.ps1 # plugin structure checks
```

MIT license.

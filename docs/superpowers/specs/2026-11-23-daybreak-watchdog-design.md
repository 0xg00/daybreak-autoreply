# Daybreak Watchdog — Design

Date: 2026-11-23
Status: Approved (with the partner's decisions)

## Intent

When Codex CLI blocks a response through the cybersecurity filter
("This content can't be shown… apply for Daybreak"), the turn dies with an
error and has to be retried by hand. This watchdog detects it and auto-sends
a configurable command (default: `/goal resume`), with no human interaction.

## Why

Daily authorized security work; the filter fires 16+ times/month
(verified in November rollouts). Manual retries break the flow, especially
with long tasks that take minutes to fail.

## Goals

- Detect ALL cyber blocks (main session and subagents).
- Auto-send configurable text, in any terminal (WT, conhost,
  VS Code, Alacritty, …).
- Never type keys outside a terminal.
- Never touch `~/.codex/config.toml` or `notify` (occupied by computer-use).
- Avoid loops: cooldown + retry cap per time window.

## Non-goals

- Picking the exact tab inside multi-tab Windows Terminal (v1 activates
  the window; with several simultaneous codex sessions, it assumes foreground).
- Bypassing the server-side filter: this retries the turn, it does not evade
  the policy; if it re-triggers, the retry cap cuts the loop.

## Detection source (key finding)

The event lands in the session rollout (`~/.codex/sessions/**/rollout-*.jsonl`,
live append):

```json
{"type":"event_msg","payload":{"type":"task_complete",
 "error":{"message":"…Daybreak…","codex_error_info":"cyber_policy"}}}
```

It also appears as `agent_message` when a subagent fails. Match pattern:
the structural `payload.error.codex_error_info` field — zero false
positives.

**Real census from the partner's machine (6 months of sessions)**:
`usage_limit_exceeded` ×3277, `cyber_policy` ×3013,
`context_window_exceeded` ×3. The TUI interstitial ("This content can't be
shown") is NOT written to rollouts — only the structural event captures
everything. The watchdog maps **code → reply**:

```json
"responses": {
  "cyber_policy": "/goal resume",
  "usage_limit_exceeded": "/goal resume",
  "context_window_exceeded": "/compact"
}
```

## Approaches

1. **Chosen — File watcher + SendInput**: tail rollouts with
   FileSystemWatcher + offsets; injection via synthetic keyboard
   (clipboard-paste + Enter). Terminal-agnostic, zero contact with Codex
   config.
2. Discarded — wrapper over `notify`: would wrap OpenAI's computer-use
   binary; fragile and touches a foreign feature.
3. Discarded — AutoHotkey + UIA screen-scrape: UIA dependency per terminal
   (VS Code doesn't cooperate); unnecessary with a jsonl source.

## Behavior

1. A PowerShell daemon watches `~/.codex/sessions/` (subdirectories,
   `*.jsonl`, new + changed files, per-file offsets).
2. Match → wait `delay_s` (3) → verify the foreground is a terminal from
   the list; if not, activate the codex parent process window; if
   impossible, wait for terminal foreground up to 120 s.
3. Inject: clipboard ← `send_text` (clipboard restored afterwards), Ctrl+V,
   Enter. Optional `press_escape_first = false`.
4. 60 s cooldown; max 3 sends / 10 min → 15 min pause.
5. `watchdog.log` logging + a Windows toast on every action.

## Config (`config.json`)

`send_text` = `/goal resume` (fallback if the code isn't in `responses`);
`responses` = code→text map (above); `delay_s` = 3; `cooldown_s` = 60;
`max_burst` = 3; `burst_window_min` = 10; `pause_after_limit_min` = 15;
`require_terminal_foreground` = true; `terminals` = [WindowsTerminal,
conhost, cmd, powershell, pwsh, Code, alacritty, wezterm-gui, mintty];
`pattern` = `"codex_error_info":"cyber_policy`.

## Files

- `watch.ps1` — daemon (watch + inject, user32 P/Invoke for
  SetForegroundWindow/SendInput; SendKeys for keys).
- `config.json`
- `stop.ps1` — kills the daemon by name.
- `README.md` — usage and limits.
- No install.ps1 (v1): **manual start** — the partner's decision.

## Accepted risks

- Collision if the user types a prompt in that exact terminal at send time
  (mitigated by the delay; adjustable).
- Multi-tab WT: activates the window, not the specific tab.

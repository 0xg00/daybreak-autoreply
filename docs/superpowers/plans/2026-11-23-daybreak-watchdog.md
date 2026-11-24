# Daybreak Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PowerShell daemon that detects Codex CLI `cyber_policy` blocks in session rollouts and auto-sends `/goal resume` (configurable) to the focused terminal.

**Architecture:** Poll every 1 s of modified `rollout-*.jsonl` files under `sessions_dir` (default `~/.codex/sessions`), incremental reads with per-file offsets and a 256-char overlap; a match requires a real JSON parse (`payload.error.codex_error_info -eq 'cyber_policy'`), not a loose substring. Injection: foreground process check against a terminal list, activating the codex parent window as fallback, clipboard paste (restored) + Enter via SendKeys. Burst control: cooldown + max N sends per window + pause.

**Tech Stack:** PowerShell 7 (pwsh), .NET FileSystemInfo/FileStream, WScript.Shell SendKeys, user32 P/Invoke (SetForegroundWindow), Windows Runtime toast (best-effort, no external modules).

**Spec:** `docs/superpowers/specs/2026-11-23-daybreak-watchdog-design.md`

## Global Constraints

- PowerShell 7+ (`pwsh`), no external modules (no Pester either: tests use a hand-rolled assert script).
- Do NOT modify anything under `~/.codex/` — read-only access to `sessions/`.
- All paths and default values exactly as the spec: `send_text="/goal resume"`, `delay_s=3`, `cooldown_s=60`, `max_burst=3`, `burst_window_min=10`, `pause_after_limit_min=15`, `require_terminal_foreground=true`, `pattern='"codex_error_info":"cyber_policy'`.
- `responses` map (`codex_error_info` code → text): `cyber_policy`→`/goal resume`, `usage_limit_exceeded`→`/goal resume`, `context_window_exceeded`→`/compact`. Global fallback: `send_text="/goal resume"`. Real census: 3277 usage, 3013 cyber, 3 context.
- `dry_run=true` in config → logs the action but sends NO keys (used by E2E tests).
- Git: new repo at the project root; commits after each task.
- Encode files as UTF-8 without BOM.

## Review Focus

1. **Pattern split across two reads** (chunk boundary): the watcher reads new bytes; the event JSON can straddle two polls → keep a 256-char tail queue and prepend it to the next read. Test in Task 1.
2. **Quoted-string false positive**: the `codex_error_info` string can appear inside a user `input_text` (pasted JSON) → a match requires an `event_msg` line + `ConvertFrom-Json` + a real field. Test in Task 1.
3. **Two sessions writing different rollouts at once** → per-file offsets in a hashtable. Test in Task 1.
4. **Foreground on a non-terminal process** (Word, browser) at send time → never send keys; wait/activate. Test in Task 2.
5. **No locatable codex parent window** → wait up to 120 s for terminal foreground; on expiry, log and abort. Test in Task 2.

---

### Task 1: Detection core (config, incremental reads, match, burst, log)

**Files:** Create `config.json`, `watch.ps1`, `tests/run-tests.ps1`.

**Interfaces (consumed by Tasks 2-3):**
- `Load-Config([string]$Path) -> [hashtable]` — defaults merged with the file if present.
- `Get-NewContent([string]$Path, [hashtable]$Offsets) -> [psobject]` with `Content [string]`, `Offset [long]` — reads from the saved offset, UTF-8, FileStream with FileShare ReadWrite|Delete; if the file shrank (rotation), reread from 0 and reset the offset.
- `Find-BlockEvent([string]$Text, [string[]]$WatchCodes) -> [string]` — the found `codex_error_info` code or `$null`; per line: only lines containing `"type":"event_msg"` get `ConvertFrom-Json`, returning `$_.payload.error.codex_error_info` if present and in `$WatchCodes`.
- `Test-BurstAllowed([datetime]$Now, [List[datetime]]$History, [hashtable]$Cfg) -> [psobject]` with `Allowed [bool]`, `History` (cooldown + burst window + post-limit pause).
- `Write-Log([string]$Msg, [hashtable]$Cfg)` — append to `log_file` with an ISO timestamp.
- Daemon loop (unless `-NoDaemon`); `param([string]$ConfigPath = "config.json", [switch]$NoDaemon)`: every 1 s enumerate `rollout-*.jsonl` with `LastWriteTime > $lastScan` under `sessions_dir` (recursive), incremental read, 256-char overlap, and on a match resolve `$cfg.responses[$code] ?? $cfg.send_text` and call `Invoke-Autorespond` (Task 2; in Task 1 a log-only stub).

TDD steps: write failing tests first (T1 chunk-boundary overlap, T1b other watched codes, T2 quoted-string false positive, T3 per-file offsets, T4 cooldown, T5 burst cap) → run and watch them fail → implement → green → commit `feat: cyber_policy detection core in rollouts`.

### Task 2: Injection (foreground, window, clipboard, SendKeys, toast)

**Files:** Modify `watch.ps1`, `tests/run-tests.ps1`.

**Interfaces:**
- `Test-IsTerminalProcess([string]$ProcName, [string[]]$Terminals) -> [bool]` — case-insensitive comparison by process name without extension.
- `Get-CodexParentTerminal() -> [IntPtr]` — enumerates `codex*`/`node`-with-codex processes, climbs to the first ancestor in the terminal list, returns its `MainWindowHandle`.
- `Invoke-Autorespond([string]$Text, [string]$Code, [hashtable]$Cfg)` — replaces the stub: `delay_s` sleep → foreground check → if not a terminal and `require_terminal_foreground`: try `Get-CodexParentTerminal` + P/Invoke `SetForegroundWindow`; if still not a terminal, poll foreground up to 120 s; then if `dry_run` → only log `DRYRUN`, else → clipboard backup (only if non-empty), `Set-Clipboard`, SendKeys `^v`, 300 ms sleep, `{ENTER}`, restore clipboard. Best-effort toast in a silent try/catch.

TDD steps: T6 (non-terminal rejected / WT and Code accepted / name-without-extension match), T7a (dry_run only logs DRYRUN, returns DRYRUN), T7b (expiry without terminal → ABORT, no DRYRUN) → fail → implement → green → commit `feat: foreground-safe injection with clipboard and sendkeys`.

### Task 3: Simulated E2E, stop.ps1, README

**Files:** Create `stop.ps1`, `README.md`, `tests/e2e-dryrun.ps1`; Modify `config.json` (flip `dry_run: false` at the end).

- E2E: isolated temp sessions dir + temp config; start the daemon as a real process; inject the spec's `event_msg` cyber_policy line twice; assert exactly one DRYRUN (cooldown dedup) and no historical replay from a pre-filled rollout.
- `stop.ps1`: kills pwsh processes whose CommandLine matches the daemon (resolved-path escaped regex + word-delimited alternative for relative launches); lists by default, `-Force` kills.
- README: usage, config table, dry_run recipe, known limits, how to stop.
- Final: all suites green; flip `dry_run=false`; commit `feat: dry-run e2e, stop script and documentation`.

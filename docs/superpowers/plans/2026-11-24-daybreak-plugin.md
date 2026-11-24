# Daybreak Autoreply Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the validated Daybreak watchdog (PowerShell) into the `daybreak-autoreply` Codex plugin: a single repo installable via a git marketplace, daemon auto-start via the `SessionStart` hook, visual control via slash commands.

**Architecture:** Hybrid plugin (spike evidence 2026-11-24: the `Stop` hook does NOT fire on turns killed by `cyber_policy`; native injection was discarded). The `watch.ps1` engine (rollout detection + delivery) lives inside the plugin in `scripts/`; the `SessionStart` hook runs `ensure-daemon.ps1` which guarantees a live daemon with state in `PLUGIN_DATA`; slash commands delegate to `scripts/daybreak-cli.ps1`.

**Tech Stack:** PowerShell 7+, JSON, `.claude-plugin` plugin format (patterns copied from `codex@openai-codex` 1.0.6 and `sol-advisor`, both real on this machine), hand-rolled assert tests without Pester.

**Spec:** `docs/superpowers/specs/2026-11-24-daybreak-plugin-design.md` (approved; includes the spike evidence matrix and the resolutions of the builder check's 6 questions).

## Global Constraints

- PowerShell 7+ (`pwsh`), no external modules, no Pester (script asserts).
- UTF-8 without BOM in all new files.
- Do NOT modify anything under `~/.codex/` except: the plugin's own entries (cache/plugin-data managed by Codex), the `[marketplaces.daybreak-dev]` entry during dev-install (Task 6), and Task 1's temporary spike artifacts (removed when the task ends). `~/.codex/sessions/` is ALWAYS read-only.
- Exact spec values in the default config: `responses = { cyber_policy, usage_limit_exceeded → reply text; context_window_exceeded → "/compact" }`, `watch_codes` = all three, `delay_s=3`, `require_terminal_foreground=true`, `foreground_wait_s=120`, `dry_run=false` (ACTIVE by default — the partner's explicit requirement). Rate keys evolved per partner request: `cooldown_s=0`, `max_burst=0` (0 = unlimited).
- State, user config and logs live in `PLUGIN_DATA` (`~/.codex/plugin-data/daybreak-autoreply/`), never in the plugin root (the cache is replaced on updates).
- Plugin and repo name: `daybreak-autoreply`. Version 0.1.0. Windows-only (declared in plugin.json and README).
- `ensure-daemon.ps1` ALWAYS ends `exit 0` even if everything inside fails (never break a `SessionStart`).
- Git: commits after each task; `v0.1.0` tag at the end.

## Review Focus

1. **Hook child dies with the hook/codex** (job object kill-on-close) → silently absent daemon, the product does nothing. Test: Task 1's spike measures a real heartbeat ≥60 s after Codex closes; Task 4 re-verifies with the real daemon.
2. **Plugin update leaves an orphan daemon** running old code from a deleted cache → ghost behavior. Test (Task 3): `Test-DaemonAlive` returns false when the PID lives but its `CommandLine` no longer points at the current `watch.ps1`, and the main flow replaces it.
3. **`PLUGIN_DATA` unreachable/corrupt in the hook** → an exception breaking session startup. Test (Task 3): invocation with an illegal `-DataDir` ends `exit 0`.
4. **Two concurrent `SessionStart`s** (two Codex windows) → two daemons sending duplicates. Test (Task 3, added during the final-review fix wave): a second call with live state and the same route is a no-op; E2E runs two parallel `-File` invocations and asserts a single daemon.
5. **User's `config.json` with a typo** → silently different defaults. Covered by `Load-Config` (warn + merge); regression test in Task 4, plus (final-review fix) unknown keys are reported and logged as WARNING.

---

### Task 1: Spike — survival of the hook's child

**Files:** Create `spike/spawn-spike.ps1`, `spike/heartbeat.ps1`, `spike/README.md`; Temporary: `~/.codex/hooks.json` (deleted at task end).

**Interfaces:** Produces the launch-mechanism VERDICT (`A: plain Start-Process survives` | `B: needs a scheduled task`), recorded in the spike README and consumed by Task 3.

Steps: write `heartbeat.ps1` (1 s beats to `spike/heartbeat.log`, stops on a flag file); write `spawn-spike.ps1` (spawns the heartbeat hidden, saves the child PID, `exit 0`); register in `~/.codex/hooks.json` and smoke-test locally; user round (new session → `/hooks` trust → close Codex) → verdict; cleanup (hooks.json deleted, heartbeats stopped) and commit with the verdict documented.

### Task 2: Plugin layout + engine relocation

**Files:** Create `.claude-plugin/plugin.json`, `hooks/hooks.json`, `tests/test-plugin-structure.ps1`; `git mv watch.ps1 stop.ps1 → scripts/`; adapt test paths.

**Interfaces:** Produces the final repo-plugin layout Tasks 3-6 assume.

Steps: `git mv` + path updates in both suites; write the structure test (manifest parses with name/version/description; hooks.json has exactly `SessionStart` referencing `ensure-daemon.ps1` via `${CLAUDE_PLUGIN_ROOT}`; scripts and commands exist; config carries the exact default values) → watch it fail → create manifest + hooks.json + command stubs → all suites green → commit.

### Task 3: `ensure-daemon.ps1` with state and flag (TDD)

**Files:** Create `scripts/ensure-daemon.ps1`; extend `tests/run-tests.ps1` (T8-T12).

**Interfaces (consumed by Tasks 4-5):**
- `Initialize-PluginData([string]$DataDir, [string]$DefaultConfigSrc) -> [string]` — creates `logs\`, copies the default config if missing, returns the user config path.
- `Test-DaemonAlive([int]$ProcId, [string]$WatchScriptPath) -> [bool]` — true only if the process exists AND is pwsh AND its `CommandLine` runs `watch.ps1` (current path).
- `Invoke-EnsureDaemon([string]$DataDir, [string]$PluginRoot, [string]$WatchScript)` — main flow: respects `disabled.flag`; reads `state.json`; live + same route → no-op; live + different route (post-update) → kill and relaunch; dead → launch; saves `state.json`.
- State files: `$DataDir\state.json`, `$DataDir\disabled.flag`, logs in `$DataDir\logs\watchdog.log`.

Tests: T8 init (creates, never overwrites a modified config), T9 aliveness (dead PID false; real watch.ps1 pwsh true; foreign pwsh false), T10 disabled flag (no state, no process), T11 double ensure (same PID), T12 illegal DataDir → `exit 0`. Implementation: whole main in try/catch, `exit 0` always, dot-source guard.

### Task 4: Engine adapted to `PLUGIN_DATA` + integration E2E

**Files:** Modify `scripts/watch.ps1` (relative `log_file` resolves next to the config); Create `tests/e2e-plugin.ps1`.

E2E (full sandbox in temp): pre-create a custom user config → `Invoke-EnsureDaemon` → live daemon → inject a cyber_policy event into a synthetic rollout → exactly one DRYRUN in `PLUGIN_DATA\logs\` → cooldown suppresses the second → repeated ensure doesn't duplicate → typo'd-config regression (good keys preserved).

### Task 5: Slash commands, CLI and README

**Files:** Create `scripts/daybreak-cli.ps1`; complete `commands/*.md`; rewrite `README.md`; T14 tests.

CLI subcommands `status|start|stop|test` (+ `set` added post-review with hot-reload): status shows PID/uptime/config/last events; stop writes the flag and stops the daemon; start clears the flag and ensures; test runs the sandbox E2E. Always `exit 0` with plain text.

### Task 6: Local dev-install + real E2E with blocks

Register `[marketplaces.daybreak-dev]` (local → repo root; a root `.agents/plugins/marketplace.json` manifest is required for local marketplaces — discovered here), `codex plugin add daybreak-autoreply@daybreak-dev`, verify the daemon bootstraps from the cache path (hook simulation with real `CLAUDE_PLUGIN_*`), then real-block verification on the partner's dying session (`QUEUE_SENT` + suppression windows), evidence log, final commit and `v0.1.0` tag.

---

## Post-plan amendments (same day, executed inline)

- **v0.2 addendum**: `codex queue` delivery to the exact session (`delivery="queue"` default; UUIDs tried in order; subagent -32600 rejections skipped).
- **Partner requests**: reply text `continua` (factory `continue`); `cooldown_s=0` / `max_burst=0` (0 = unlimited; blocks inside the delay window still sent).
- **Incident fix**: `sendkeys_fallback=false` by default + queue without `--resume` + per-thread loop breaker (`per_thread_max/window/pause`; 0 = off).
- **Final review (opus) fix wave**: portability (no absolute `sessions_dir` in the default config; quoted spawn args — verified exit 64 without quotes), identity-checked kills (`Test-IsWatchProcess`), anti-duplicate mutex (`ensure.lock`), unknown-config-keys WARNING (visible in status).
- **`/daybreak-set <text>`** with daemon hot-reload (config re-read every loop iteration; E11 proves a live text change is used without restart).

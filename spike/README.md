# Research spikes — evidence that fixed design decisions

## Spike 1 (stop-logger.ps1): does the Stop hook fire on turns killed by errors?

NO. Matrix measured on 2026-11-24 with a log-only hook:

| event | fires? |
|---|---|
| SessionStart (startup/resume) | yes |
| Stop after a normal turn | yes |
| Stop after a turn killed by a cyber_policy error | **NO** (2 real blocks, zero deliveries) |

Consequence: the fully-native injection path (`decision:"block"` + reason) is discarded; the SendKeys engine was necessary at that point.

## Spike 2 (spawn-spike.ps1 + heartbeat.ps1): does a detached child survive the death of the codex process?

YES (verdict A, `Start-Process -WindowStyle Hidden` mechanism):
- Child beating for 29+ min with a single pid and a max 2 s gap (outlives the hook's exit).
- An ephemeral `codex exec` (exit 0, process gone) left a child that kept beating → no job-object kill-on-close exists.

Consequence: `ensure-daemon.ps1` can launch the daemon from the SessionStart hook with a plain Start-Process; no scheduled task needed.

Additional lesson: Windows hook commands with quoted paths containing spaces fail the spawn silently; `${CLAUDE_PLUGIN_ROOT}` (no spaces) + pwsh works.

# Spikes de investigación — evidencia que fijó decisiones de diseño

## spike 1 (stop-logger.ps1): ¿dispara el hook Stop en turnos muertos?

NO. Matriz medida el 2026-11-24 con hook log-only:

| evento | dispara |
|---|---|
| SessionStart (startup/resume) | sí |
| Stop tras turno normal | sí |
| Stop tras turno con error cyber_policy | **NO** (2 bloques reales, cero entregas) |

Consecuencia: la inyección 100 % nativa (`decision:"block"` + reason) está descartada; el motor SendKeys es necesario.

## spike 2 (spawn-spike.ps1 + heartbeat.ps1): ¿sobrevive un hijo detached a la muerte del proceso codex?

SÍ (VEREDICTO A, mecanismo `Start-Process -WindowStyle Hidden`):
- Hijo latiendo 29+ min con pid único y gap máx 2 s (sobrevive al exit del hook).
- `codex exec` efímero (exit 0, proceso muerto) dejó un hijo que siguió latiendo → no existe job-object kill-on-close.

Consecuencia: `ensure-daemon.ps1` puede lanzar el daemon desde el hook SessionStart con Start-Process directo; no hace falta tarea programada.

Lección adicional: los comandos de hook en Windows con rutas entrecomilladas con espacios al inicio fallan el spawn de forma silenciosa; `${CLAUDE_PLUGIN_ROOT}` (sin espacios) + pwsh funciona.

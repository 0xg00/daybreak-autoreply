# Daybreak Watchdog — Design

Fecha: 2026-11-23
Estado: Aprobado (con decisiones del socio)

## Intent

Cuando Codex CLI bloquea una respuesta por el filtro de ciberseguridad
("This content can't be shown… apply for Daybreak"), el turno muere con un
error y hay que reintentar a mano. Este watchdog lo detecta y auto-envía un
comando configurable (default: `/goal resume`), sin interacción humana.

## Por qué

Trabajo de seguridad autorizado diario; el filtro salta 16+ veces/mes
(verificado en rollouts de noviembre). Reintentar a mano rompe el flujo,
sobre todo con tasks largos que tardan minutos en fallar.

## Goals

- Detectar TODOS los bloqueos cyber (sesión principal y subagentes).
- Auto-enviar texto configurable, en cualquier terminal (WT, conhost,
  VS Code, Alacritty, …).
- Nunca escribir teclas fuera de una terminal.
- Nunca tocar `~/.codex/config.toml` ni `notify` (ocupado por computer-use).
- Evitar bucles: cooldown + límite de reintentos por ventana de tiempo.

## Non-goals

- Elegir pestaña exacta dentro de Windows Terminal multi-pestaña (v1 activa
  la ventana; si hay varias sesiones codex simultáneas, asume foreground).
- Bypass del filtro del servidor: esto reintenta el turno, no evade la
  política; si re-dispara, el límite de reintentos corta el bucle.

## Fuente de detección (hallazgo clave)

El evento queda en el rollout de sesión (`~/.codex/sessions/**/rollout-*.jsonl`,
append en vivo):

```json
{"type":"event_msg","payload":{"type":"task_complete",
 "error":{"message":"…Daybreak…","codex_error_info":"cyber_policy"}}}
```

También aparece como `agent_message` cuando falla un subagente. Patrón de
match: campo estructural `payload.error.codex_error_info` — cero falsos
positivos.

**Censo real de la máquina del socio (6 meses de sesiones)**:
`usage_limit_exceeded` ×3277, `cyber_policy` ×3013,
`context_window_exceeded` ×3. El interstitial TUI ("This content can't be
shown") NO se escribe en rollouts — solo el evento estructural lo captura
todo. El watchdog mapea **código → respuesta**:

```json
"responses": {
  "cyber_policy": "/goal resume",
  "usage_limit_exceeded": "/goal resume",
  "context_window_exceeded": "/compact"
}
```

## Enfoques

1. **Elegido — Watcher de archivos + SendInput**: tail de rollouts con
   FileSystemWatcher + offsets; inyección con teclado sintético
   (clipboard-paste + Enter). Terminal-agnóstico, cero contacto con config
   de Codex.
2. Descartado — wrapper sobre `notify`: envolvería el binario de
   computer-use de OpenAI; frágil y toca feature ajena.
3. Descartado — AutoHotkey + UIA screen-scrape: dependencia de UIA por
   terminal (VS Code no coopera); innecesario con fuente jsonl.

## Comportamiento

1. Daemon PowerShell vigila `~/.codex/sessions/` (subdirectorios,
   `*.jsonl`, archivos nuevos + cambios, offsets por archivo).
2. Match → espera `delay_s` (3) → verifica foreground sea terminal de la
   lista; si no, activa ventana del proceso padre de codex; si imposible,
   espera foreground terminal hasta 120 s.
3. Inyecta: clipboard ← `send_text` (restaura clipboard después), Ctrl+V,
   Enter. `press_escape_first = false` opcional.
4. Cooldown 60 s; máx 3 disparos / 10 min → pausa 15 min.
5. Log `watchdog.log` + toast de Windows en cada acción.

## Config (`config.json`)

`send_text` = `/goal resume` (fallback si el código no está en `responses`);
`responses` = mapa código→texto (arriba); `delay_s` = 3; `cooldown_s` = 60;
`max_burst` = 3; `burst_window_min` = 10; `pause_after_limit_min` = 15;
`require_terminal_foreground` = true; `terminals` = [WindowsTerminal,
conhost, cmd, powershell, pwsh, Code, alacritty, wezterm-gui, mintty];
`pattern` = `"codex_error_info":"cyber_policy`.

## Archivos

- `watch.ps1` — daemon (watch + inject, P/Invoke user32 para
  SetForegroundWindow/SendInput; SendKeys para teclas).
- `config.json`
- `stop.ps1` — mata el daemon por nombre.
- `README.md` — uso y límites.
- Sin install.ps1 (v1): **arranque manual** — decisión del socio.

## Riesgos aceptados

- Colisión si el usuario teclea un prompt en la terminal exacta en el
  momento del envío (mitigado por delay; ajustable).
- Multi-pestaña WT: activa la ventana, no la pestaña específica.

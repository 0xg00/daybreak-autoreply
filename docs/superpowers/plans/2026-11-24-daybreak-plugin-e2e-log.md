# Bitácora E2E real — plugin daybreak-autoreply (2026-11-24)

Verificación en producción sobre sesiones reales del socio (sin sandbox).

## Instalación dev (CLI, sin TUI)

- `/plugins` vacío con marketplace local → causa: los marketplaces locales exigen manifiesto raíz. Creado `.agents/plugins/marketplace.json` (esquema copiado de `openai-bundled`).
- `codex plugin add daybreak-autoreply@daybreak-dev` → cache `~/.codex/plugins/cache/daybreak-dev/daybreak-autoreply/0.1.0` + registro en config.toml línea `[plugins."daybreak-autoreply@daybreak-dev"]`.

## Motor v1 (SendKeys)

- Daemon levantado simulando el hook (env `CLAUDE_PLUGIN_ROOT/DATA` + `ensure-daemon.ps1`).
- 2 envíos reales verificados: `AUTORESPOND … 19:50:03` y `19:51:10` (foreground=WindowsTerminal).
- Feedback del socio: cooldown/ráfaga (60 s, 3/10 min) suprimía su bucle bloqueo→resume; teclas iban a la ventana con foco, no a la sesión bloqueada.

## Motor v2 (codex queue) — verificado extremo a extremo

- `QUEUE_SENT` reales: 19:58:31, 19:58:46, 19:58:55 (thread 01a208d7… y 01a20ec8…), con message-id devuelto por codex.
- Entrega confirmada EN el rollout destino: items `/goal resume` aparecen en `rollout-…01a208d7-fd7f…jsonl` a las 18:58:59–18:59:16Z (19:58–19:59 local), tras los QUEUE_SENT.
- Subagentes rechazan el encolado (-32600) y el motor salta al siguiente UUID del nombre — observado y manejado.
- `--resume` advierte "start a local daemon" (warning a log, no fallo): con el TUI abierto la entrega ocurre igual.

## Ritmo y texto (peticiones del socio)

- cooldown 5 s + válvula 50/10 min (anti-bucle desbocado): MATCH→QUEUE_SENT cada bloque, supresión solo dentro de la ventana de 5 s (visible en log 19:58:59).
- Texto cambiado a `continua` (cyber_policy, usage_limit_exceeded, send_text; `/compact` se mantiene para context_window_exceeded). Daemon reiniciado pid 21592 con el mapa nuevo a las 20:00:51.

## Pendiente del socio (no bloquea el funcionamiento)

- Confiar el hook SessionStart del plugin vía `/hooks` en la próxima sesión → autostart tras reinicios de máquina (el daemon vivo ya sobrevive a todo lo demás: veredicto A del spike).

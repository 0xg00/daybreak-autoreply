# Daybreak Watchdog

Daemon en PowerShell 7 que vigila los rollouts de sesión de Codex CLI
(`~/.codex/sessions/**/rollout-*.jsonl`, append en vivo) y auto-responde los
turnos muertos. Cuando Codex graba en el rollout un error estructural
(`payload.error.codex_error_info`) con un código vigilado, el watchdog espera
unos segundos, comprueba que un terminal esté en primer plano, pega la
respuesta asociada a ese código en el portapapeles, la envía con Ctrl+V + Enter
al terminal donde corre el codex y lo avisa con un toast.

Respuestas por defecto:

| Código vigilado        | Respuesta inyectada |
|------------------------|---------------------|
| `cyber_policy`         | `/goal resume`      |
| `usage_limit_exceeded` | `/goal resume`      |
| `context_window_exceeded` | `/compact`       |

Requisitos: Windows, PowerShell 7 (`pwsh`). Sin módulos externos; todo el
comportamiento se ajusta desde `config.json`.

## Arranque manual

```powershell
cd C:\ruta\a\daybreak-watchdog
pwsh -NoProfile -File watch.ps1
```

Con otra config: `pwsh -NoProfile -File watch.ps1 -ConfigPath C:\ruta\otra-config.json`.
Sin el loop daemon (solo funciones, para pruebas): añade `-NoDaemon`.

### Versión minimizada / oculta (acceso directo)

Crea un acceso directo (.lnk) con:

- **Destino:** `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -WindowStyle Hidden -File "C:\ruta\a\daybreak-watchdog\watch.ps1"`
- **Iniciar en:** la carpeta del proyecto (importante: así encuentra `config.json`;
  si lo arrancas desde otra carpeta, pasa `-ConfigPath` con ruta absoluta).

La ventana queda oculta; para pararlo en ese modo usa `stop.ps1` (abajo).

## config.json — todas las claves

Si una clave falta o el archivo no existe, se usa el default de la tabla
(configuración parcial válida).

| Clave | Default | Qué hace |
|---|---|---|
| `sessions_dir` | `%USERPROFILE%\.codex\sessions` | Carpeta raíz (búsqueda recursiva) donde vigilar `rollout-*.jsonl`. |
| `log_file` | `watchdog.log` | Registro de arranques, `MATCH`, `DRYRUN`/`AUTORESPOND`, `ABORT` y errores. |
| `send_text` | `/goal resume` | Respuesta por defecto si el código detectado no tiene entrada en `responses`. |
| `responses` | `cyber_policy`→`/goal resume`, `usage_limit_exceeded`→`/goal resume`, `context_window_exceeded`→`/compact` | Mapa código→texto que se pega y envía en el terminal. |
| `watch_codes` | `cyber_policy`, `usage_limit_exceeded`, `context_window_exceeded` | Códigos `codex_error_info` que disparan la auto-respuesta. |
| `delay_s` | `3` | Segundos de espera tras detectar antes de tocar el terminal (margen para soltar el teclado). |
| `cooldown_s` | `60` | Segundos mínimos entre disparos: dedup del mismo evento repetido. |
| `max_burst` | `3` | Máximo de disparos dentro de `burst_window_min`. |
| `burst_window_min` | `10` | Ventana de ráfaga en minutos. |
| `pause_after_limit_min` | `15` | Pausa tras agotar la ráfaga (`max_burst` en la ventana) antes de volver a disparar. |
| `require_terminal_foreground` | `true` | Exigir que el proceso en primer plano sea un terminal antes de enviar; si no lo es, intenta traer la ventana del codex y espera. Con `false` envía sin comprobar nada. |
| `foreground_wait_s` | `120` | Segundos que espera a que un terminal quede en primer plano antes de abortar (`ABORT` en el log, sin enviar). |
| `terminals` | `WindowsTerminal`, `conhost`, `cmd`, `powershell`, `pwsh`, `Code`, `alacritty`, `wezterm-gui`, `mintty` | Procesos que cuentan como terminal válido para el chequeo de foreground. |
| `dry_run` | `true` (en el repo) | `true`: solo loguea `DRYRUN code=… texto=…`, no toca portapapeles ni teclas. `false`: envía de verdad. |

> El repo se entrega con `dry_run: true`. Cámbialo a `false` solo cuando
> quieras que el watchdog actúe de verdad.

## Cómo probar con `dry_run`

`dry_run` hace todo el recorrido (detección, delay, gates) pero en lugar de
pegar/enviar escribe en el log una línea `DRYRUN`. Para probarlo necesitas un
rollout que el daemon vea. Lo limpio es un `sessions_dir` temporal **aislado**
(nunca apuntes una config de prueba a tu `~/.codex/sessions` real: ahí hay
sesiones activas y un fallo del gate enviaría teclas de verdad):

```powershell
# 1) config temporal de prueba
$t = "$env:TEMP\daybreak-prueba"
New-Item -ItemType Directory "$t\sessions\2026\11\23" -Force | Out-Null
@{ sessions_dir = "$t\sessions"; log_file = "$t\watchdog.log";
   dry_run = $true; delay_s = 0; require_terminal_foreground = $false } |
  ConvertTo-Json | Set-Content "$t\config.json"

# 2) arrancar el daemon apuntando a esa config
pwsh -NoProfile -File watch.ps1 -ConfigPath "$t\config.json"

# 3) en otra terminal, fabricar el rollout fake: append de la línea event_msg del spec
Add-Content "$t\sessions\2026\11\23\rollout-test.jsonl" `
  '{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Daybreak","codex_error_info":"cyber_policy"}}}'

# 4) comprobar el log: debe aparecer MATCH + una linea DRYRUN (una sola vez por cooldown)
Get-Content "$t\watchdog.log" -Tail 5
```

O directamente, automatizado: `pwsh -File tests/e2e-dryrun.ps1` (levanta el
daemon real contra un temporal aislado, inyecta la línea y verifica el log).
La suite unitaria completa va aparte: `pwsh -File tests/run-tests.ps1`.

## Límites conocidos

- **Multi-pestaña en Windows Terminal:** se activa la *ventana* de WT, no la
  *pestaña* concreta donde vive el codex. Si el codex no está en la pestaña
  activa, el texto puede ir a la pestaña que esté visible.
- **Colisión con tu escritura:** si estás escribiendo tú en esa terminal
  exacta en el momento del envío, tu texto y el pegado pueden entremezclarse.
  `delay_s` (3 s por defecto) da un margen, pero no evita la colisión si
  escribes justo durante el pegado.
- **Toast:** puede no hacer nada (no-op) en PowerShell 7.4+ (WinRT
  best-effort). El disparo queda registrado en el log de todos modos.
- **Terminal no listada:** si el codex corre en un proceso que no está en
  `terminals`, el watchdog nunca envía (lo aborta con `ABORT` en el log tras
  `foreground_wait_s`).

## Cómo parar

```powershell
pwsh -NoProfile -File stop.ps1          # lista lo que detendría (no hace nada)
pwsh -NoProfile -File stop.ps1 -Force   # lo detiene
```

`stop.ps1` solo toca procesos cuyo comando apunta a `watch.ps1` (nunca mata
por nombre de proceso a secas) y sale con código 1 si no hay nada que parar.
Si el daemon corre en una ventana visible, también puedes pararlo cerrando
esa ventana directamente.

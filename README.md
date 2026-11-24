# daybreak-autoreply

Plugin de Codex CLI que **responde automáticamente a los bloqueos de ciberseguridad** (el famoso "This content can't be shown… apply for Daybreak"). Cuando un turno muere por `cyber_policy`, el plugin envía solo el comando que configures — por defecto `/goal resume` — a la terminal donde corre Codex. Sin tocar el teclado.

**Windows-only**: el motor usa SendKeys, portapapeles y CIM.

## Cómo funciona

1. Detecta el bloqueo leyendo los rollouts de sesión (`~/.codex/sessions/**/rollout-*.jsonl`, solo lectura) — el campo estructural `payload.error.codex_error_info`, no texto suelto. Latencia de detección: ~1-2 s.
2. Tras `delay_s` (3 s por defecto), inyecta tu texto **en la sesión bloqueada exacta** con `codex queue --thread <uuid> --message <texto> --resume`: sin teclado, sin robar foco, funciona con el codex en cualquier pestaña y tú en cualquier aplicación. UUIDs de subagentes que rechazan el encolado se saltan solos; si ninguno entra, cae al modo legacy SendKeys (foreground-safe).
3. Sin límites de ritmo por defecto: cada bloque recibe su respuesta (cooldown y burst en `0` = ilimitados; pon valores > 0 si quieres una válvula anti-bucle).

Mapa por defecto (editable):

| código | respuesta |
|---|---|
| `cyber_policy` | `/goal resume` |
| `usage_limit_exceeded` | `/goal resume` |
| `context_window_exceeded` | `/compact` |

## Instalación

1. Añade el marketplace a `~/.codex/config.toml` (repo publicado en GitHub; sustituye la URL por la tuya):

```toml
[marketplaces.daybreak]
source_type = "git"
source = "https://github.com/TU-USUARIO/daybreak-autoreply.git"
```

Para desarrollo local: `source_type = "local"` y `source = '<ruta absoluta del repo>'`.

2. En Codex CLI: `/plugins` → pestaña del marketplace → **Install** `daybreak-autoreply`.
3. `/hooks` → confía el hook `SessionStart` del plugin (una vez; Codex avisa al arranque si queda pendiente).
4. Abre una sesión nueva. El hook arranca el daemon solo — no hay paso 5.

> ⚠️ **Activo por defecto**: `dry_run=false`. Instalar y abrir sesión = el watchdog queda armado y enviará el comando real en el próximo bloqueo. Si quieres probar sin teclas reales primero, edita `config.json` (ver abajo) y pon `"dry_run": true`, o ejecuta `/daybreak-test` que corre un sandbox aislado.

## Slash commands

| comando | qué hace |
|---|---|
| `/daybreak-status` | PID, uptime, config, últimos 5 disparos |
| `/daybreak-test` | E2E sandbox (DRYRUN, sin teclas reales) |
| `/daybreak-stop` | apagado **persistente** (sobrevive sesiones) |
| `/daybreak-start` | reactiva y arranca |

## Configuración

El archivo vive en `~/.codex/plugin-data/daybreak-autoreply/config.json` (se crea la primera vez; editar y hacer `/daybreak-stop` + `/daybreak-start` para recargar).

| clave | default | significado |
|---|---|---|
| `sessions_dir` | `~/.codex/sessions` | dónde vigilar rollouts |
| `responses` | mapa de arriba | código → texto a enviar |
| `watch_codes` | los tres | códigos que disparan |
| `send_text` | `/goal resume` | fallback si el código no está en `responses` |
| `delivery` | `queue` | `queue` = inyecta en LA sesión vía `codex queue` (sin teclado ni foco); `sendkeys` = modo legacy con gates de foreground |
| `delay_s` | `3` | espera tras detectar (bloques que caen dentro se envían igual) |
| `cooldown_s` | `0` | mínimo entre disparos (`0` = sin cooldown) |
| `max_burst` / `burst_window_min` | `0` / `10` | `0` = sin máximo (válvula opcional anti-bucle desbocado) |
| `pause_after_limit_min` | `15` | pausa tras agotar la ráfaga |
| `require_terminal_foreground` | `true` | jamás teclear si el foco no es terminal |
| `terminals` | 9 procesos | lista de terminales válidas (WT, conhost, cmd, powershell, pwsh, Code, alacritty, wezterm, mintty) |
| `foreground_wait_s` | `120` | espera máx. a que el foco vuelva a terminal |
| `dry_run` | `false` | `true` = solo loguear, no enviar |
| `log_file` | `logs/watchdog.log` | relativo al dir de datos del plugin |

## Actualizar

`/plugins` → reinstall/update. El hook cambia de hash → `/hooks` → re-confiar (Codex avisa al arranque). El daemon viejo se detecta y reemplaza solo (saneo por ruta en `state.json`).

## Límites conocidos

- **Multi-pestaña en Windows Terminal**: SendKeys va a la ventana con foco; con varias abiertas puede caer en otra (mitigado por el gate de foreground + cooldown).
- **Colisión con tu escritura**: hay una ventana de ~500 ms de pegado+Enter en la que no debes teclear.
- **Toast**: requiere PowerShell 7.4+ (best-effort, sin toast todo lo demás funciona).
- Depende del formato interno de rollouts de Codex; si OpenAI lo cambia, hay que adaptar el parser.

## Desarrollo

```powershell
pwsh -File tests/run-tests.ps1            # 46 asserts unit
pwsh -File tests/e2e-plugin.ps1           # E2E integración (sandbox)
pwsh -File tests/e2e-dryrun.ps1           # E2E motor (sandbox)
pwsh -File tests/test-plugin-structure.ps1 # estructura del plugin
```

Licencia MIT.

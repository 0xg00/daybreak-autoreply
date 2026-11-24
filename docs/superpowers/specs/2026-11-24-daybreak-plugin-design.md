# Daybreak Autoreply — Plugin de Codex (Diseño)

**Fecha:** 2026-11-24
**Estado:** pendiente de aprobación
**Sustituye a:** `2026-11-23-daybreak-watchdog-design.md` como visión de producto (el watchdog PowerShell queda como motor interno; su spec sigue siendo válida para el comportamiento del motor).

## Intent

Cuando Codex CLI mata un turno por política de ciberseguridad (`codex_error_info: "cyber_policy"` — el bloqueo "apply for Daybreak"), el plugin envía automáticamente el texto configurado por el usuario (por defecto `/goal resume`) a la terminal donde corre Codex. Sin interacción humana, siempre. El envío es configurable por código de error.

El empaquetado es un **plugin de Codex** (formato `.claude-plugin`) para que instalarlo, activarlo y distribuirlo en GitHub sea trivial y visual (`/plugins` → Enter).

## Por qué (why)

- El socio trabaja en seguridad y sufre el bloqueo a diario (censo real de su máquina: 3.277 `usage_limit_exceeded`, 3.013 `cyber_policy`, 3 `context_window_exceeded`). Su bucle manual actual: bloqueo → sesión muerta → `/resume` → mensaje → bloqueo al instante.
- Quiere el mismo auto-responder del watchdog pero **como plugin**: más fácil de instalar para cualquiera y publicable en GitHub.

## Evidencia empírica que fija la arquitectura (spike 2026-11-24)

Hook log-only instalado en `~/.codex/hooks.json` durante un día real de trabajo:

| Evento | ¿Dispara? | Evidencia |
|---|---|---|
| `SessionStart` (startup y resume) | Sí | 17:47:25 (`src=resume`), 17:52:13 (`src=startup`), con `session_id` y `transcript_path` |
| `Stop` en turno normal | Sí | 17:52:24, con `last_assistant_message` |
| `Stop` en turno muerto por `cyber_policy` | **NO** | 17:42:43 y 17:49:33 — cero entregas al hook |

Conclusión: la vía 100 % nativa (`Stop` → `decision:"block"` → prompt inyectado) está descartada por evidencia. La inyección de teclado sintético (motor watchdog ya validado) sigue siendo necesaria.

Lección operativa del spike: los comandos de hook en Windows deben evitar rutas con espacios/comillas al inicio (spawn roto). El patrón que funciona: `cmd /c` + ruta 8.3 (`C:\PROGRA~1\POWERS~1\7\pwsh.exe`) o variables tipo `${CLAUDE_PLUGIN_ROOT}` con paths sin espacios. El plugin oficial `codex@openai-codex` usa `${CLAUDE_PLUGIN_ROOT}/scripts/...` en esta misma máquina y funciona.

## Goals

1. **Núcleo intacto**: todo bloqueo vigilado (default: los tres códigos del censo — `cyber_policy`, `usage_limit_exceeded`, `context_window_exceeded`) → envío automático del texto configurado por código (default: `/goal resume`, `/goal resume`, `/compact`). Detección en ≤ ~2 s del evento; el envío ocurre tras `delay_s` (default 3 s, configurable) para dejar renderizar el error.
2. Instalación de 3 pasos para cualquier usuario de Windows con Codex CLI: clonar/declarar marketplace → `/plugins` → Install. Sin pasos manuales posteriores: el hook `SessionStart` arranca el motor solo.
3. Control visual dentro de Codex: `/daybreak-status`, `/daybreak-test`, `/daybreak-stop`, `/daybreak-start`.
4. Repo único en GitHub = plugin instalable + código + tests + README.
5. Config editable (`config.json` en el dir de datos del plugin): mapa código→texto, cooldown, ráfaga, terminales.

## Non-goals

- macOS/Linux (el motor usa SendKeys/CIM/Win32 — Windows only, declarado en README).
- UI gráfica fuera de Codex (dashboard web, tray icon). "Visual" = navegación `/plugins` + slash commands.
- Disparo instantáneo post-`/resume` (refinamiento C, diferido a v0.2 si se pide).
- Modificar nada bajo `~/.codex/` salvo los archivos propios del plugin (cache del plugin, `plugin-data`, entradas de marketplace/plugins que Codex gestiona).

## Anti-goals

- Que el usuario tenga que tocar el teclado tras un bloqueo para que la respuesta salga (si pasa, es un fallo, no un límite).
- Perder el comportamiento del watchdog ya testeado (36 asserts verdes) al empaquetar.

## Arquitectura (approach A — híbrido con motor embebido)

```
repo GitHub (daybreak-autoreply)/
├── .claude-plugin/plugin.json        # manifest: name, version, description
├── hooks/hooks.json                  # SessionStart → scripts/ensure-daemon.ps1
├── scripts/
│   ├── watch.ps1                     # motor (actual watch.ps1, parametrizado)
│   ├── ensure-daemon.ps1             # arranca motor si no corre; sanea tras update
│   └── stop.ps1                      # parada limpia
├── commands/
│   ├── daybreak-status.md            # estado, uptime, últimos disparos
│   ├── daybreak-test.md              # DRYRUN sandbox con evento sintético
│   ├── daybreak-stop.md              # apagar persistente (flag disabled)
│   └── daybreak-start.md             # reactivar (quita flag)
├── tests/                            # suites existentes + nuevas (adaptadas a rutas)
├── config.json                       # config por defecto (se copia a PLUGIN_DATA en 1ª ejecución)
└── README.md                         # qué es, instalación, config, límites
```

### Flujo

1. Usuario declara el marketplace git y hace `/plugins` → Install.
2. Codex confía los hooks del plugin vía `/hooks` (flujo estándar de confianza, una vez).
3. En cada `SessionStart` (startup o resume), `ensure-daemon.ps1` comprueba un state file en `PLUGIN_DATA` (PID + ruta del script). Si el proceso vivo no existe o la ruta cambió (update del plugin), lanza `watch.ps1` detached (`-WindowStyle Hidden`) con `-ConfigPath` apuntando a `PLUGIN_DATA/config.json`. Primera ejecución: copia el `config.json` por defecto allí y crea el dir de logs.
4. `watch.ps1` (motor, comportamiento idéntico al watchdog actual): poll 1 s de rollouts, detección estructural por parse JSON (`payload.error.codex_error_info`), gates foreground-safe, clipboard backup/restore + SendKeys, cooldown + ráfaga + pausa. Logs a `PLUGIN_DATA/watchdog.log`.
5. Bloqueo real → motor envía el texto del mapa `responses` → Codex recibe `/goal resume` como si el usuario lo tecleara.

### Decisiones de diseño (calls)

- **Activo por defecto**: `dry_run=false` en la config por defecto (requisito explícito del socio: "directamente envíe lo que yo quiera"). El gate `require_terminal_foreground=true` sigue protegiendo contra teclas a ventanas ajenas. El README lo advierte en negrita para terceros.
- **Datos fuera de la cache**: config, logs y state viven en `PLUGIN_DATA` (`~/.codex/plugin-data/...`), nunca en la raíz del plugin (la cache se reemplaza en cada update).
- **Rutas de hook sin comillas iniciales**: patrón `${CLAUDE_PLUGIN_ROOT}` (sin espacios) + `pwsh` resuelto por PATH o ruta 8.3 — lección del spike.
- **Comandos de hook**: `type:"command"`, `timeout` corto (10 s) para `SessionStart`; el daemon se lanza detached y el hook vuelve inmediatamente.
- **Nombre**: `daybreak-autoreply` (plugin y repo). Versión inicial 0.1.0.
- Los slash commands son `.md` de prompt: status lee state file/log y los muestra; stop/start solo tocan el flag `disabled` en `PLUGIN_DATA` (y paran proceso si corre); test ejecuta el harness sandbox. Sin mutaciones fuera de `PLUGIN_DATA`.

## Restricciones

- PowerShell 7+, sin módulos externos (igual que el watchdog).
- No escribir jamás en `~/.codex/sessions/` (solo lectura).
- UTF-8 sin BOM en todos los archivos.
- Tests siguen siendo scripts de asserts propios (sin Pester) + E2E con sandbox aislado.

## Riesgos conocidos (heredados del watchdog, documentados)

- Multi-pestaña en Windows Terminal: SendKeys va a la ventana con foco; si hay varias, puede caer en la equivocada (mitigado por gate de foreground + cooldown).
- Colisión con escritura del usuario durante el pegado (ventana de ~500 ms).
- Toast nativo requiere PS 7.4+ (best-effort, ya con try/catch).
- El motor depende de rutas internas de Codex (`~/.codex/sessions/**/rollout-*.jsonl`): si OpenAI cambia el formato, hay que adaptarlo (riesgo aceptado; ya cambió antes y el parse estructural es tolerante).

## Preguntas del builder check y sus resoluciones

El check independiente (2026-11-24) planteó 6 puntos; ninguno queda abierto:

1. **¿Sobrevive el daemon spawneado por el hook a la salida del hook?** (linchpin de la arquitectura; el spike solo probó que los hooks disparan, no que los hijos sobrevivan). **Resolución: spike pre-build (Task 0 del plan)** — esqueleto de plugin con SessionStart que lanza un hijo heartbeat; se verifica supervivencia tras salir el hook y cerrar la sesión. Si muere (job object con kill-on-close), se cambia el mecanismo de lanzamiento (cadena `cmd /c start` con re-parentado o tarea programada) ANTES de construir el resto.
2. **¿Layout de marketplace single-repo?** **Resuelto por evidencia local**: `sol-advisor` es un repo git único instalado como marketplace de sí mismo (`[plugins."sol-advisor@sol-advisor"]` en config.toml), con manifest del plugin en la raíz del repo. Nuestro repo replica ese patrón con `.claude-plugin/plugin.json` (formato que `superpowers` y otros usan en la cache de Codex). Sin repo marketplace separado.
3. **¿Qué códigos y tiempos por defecto?** **Resuelto por spec aprobada + censo**: los tres códigos con el mapa `responses` del watchdog (spec 2026-11-23 aprobada; `usage_limit_exceeded` es el bucket mayor — 3.277 — y el socio pidió "directamente envíe"). Meta de tiempo reformulada: detección ≤ ~2 s, envío tras `delay_s` (default 3 s, deliberado). El README avisa a terceros del auto-retry en rate limit (amortiguado por `pause_after_limit_min`).
4. **¿Qué ejercita `/daybreak-test`?** **Call**: sandbox estilo `e2e-dryrun.ps1` — instancia aislada del motor con rollout sintético en temp, `dry_run` forzado. Nunca toca el daemon vivo ni envía teclas reales. Los comandos quedan: status/stop/start mutan solo flag de estado; test ejecuta el harness sandbox.
5. **¿`/daybreak-stop` es temporal o persistente?** **Call**: persistente — escribe flag `disabled` en `PLUGIN_DATA` que `ensure-daemon.ps1` respeta; `/daybreak-start` lo quita. Sin flag, matar el proceso solo pararía hasta la próxima sesión ( experiencia "inmortal" confusa).
6. **¿Trust de hooks tras update?** **Resuelto por docs oficiales**: el trust se registra por hash → hooks cambiados quedan en revisión y se saltan con aviso al arranque hasta re-confiar vía `/hooks`. El README lo documenta en la sección de actualizaciones; el saneo "ruta cambió" de ensure-daemon cubre el daemon viejo huérfano.

## Qué queda para el que construya

- Mover/adaptar `watch.ps1`, `stop.ps1` y tests al layout del plugin (paths por parámetro, sin rutas hardcodeadas al repo viejo).
- `ensure-daemon.ps1` con state file (PID + ruta + saneo tras update).
- Manifest, hooks.json, tres commands, README de instalación vía marketplace git.
- Actualizar suites y dejar 100 % verde; E2E manual final en la "sesión moribunda" real del socio (bloqueo en segundos = banco de pruebas perfecto).

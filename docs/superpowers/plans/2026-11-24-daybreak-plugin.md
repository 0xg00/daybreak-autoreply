# Daybreak Autoreply Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convertir el watchdog Daybreak (PowerShell validado) en el plugin de Codex `daybreak-autoreply`: repo único instalable vía marketplace git, auto-arranque del daemon por hook `SessionStart`, control visual con slash commands.

**Architecture:** Plugin híbrido (evidencia del spike 2026-11-24: el hook `Stop` NO dispara en turnos muertos por `cyber_policy`; la inyección nativa está descartada). El motor `watch.ps1` (detección por rollouts + SendKeys) vive dentro del plugin en `scripts/`; el hook `SessionStart` ejecuta `ensure-daemon.ps1` que garantiza un daemon vivo con estado en `PLUGIN_DATA`; slash commands delegan en `scripts/daybreak-cli.ps1`.

**Tech Stack:** PowerShell 7+, JSON, formato plugin `.claude-plugin` (patrones copiados de `codex@openai-codex` 1.0.6 y `sol-advisor`, ambos reales en esta máquina), tests de asserts propios sin Pester.

**Spec:** `docs/superpowers/specs/2026-11-24-daybreak-plugin-design.md` (aprobada; incluye matriz de evidencia del spike y resolución de las 6 preguntas del builder check).

## Global Constraints

- PowerShell 7+ (`pwsh`), sin módulos externos, sin Pester (asserts de script).
- UTF-8 sin BOM en todos los archivos nuevos.
- NO modificar nada bajo `~/.codex/` salvo: entradas propias del plugin (cache/plugin-data que gestiona Codex), la entrada `[marketplaces.daybreak-dev]` durante dev-install (Task 6), y los artefactos temporales del spike del Task 1 (se eliminan al terminar el task). `~/.codex/sessions/` es solo lectura SIEMPRE.
- Valores exactos de la spec en la config por defecto: `responses = { cyber_policy: "/goal resume", usage_limit_exceeded: "/goal resume", context_window_exceeded: "/compact" }`, `watch_codes` = los tres, `send_text="/goal resume"`, `delay_s=3`, `cooldown_s=60`, `max_burst=3`, `burst_window_min=10`, `pause_after_limit_min=15`, `require_terminal_foreground=true`, `foreground_wait_s=120`, `dry_run=false` (ACTIVO por defecto — requisito explícito del socio).
- Estado, config del usuario y logs viven en `PLUGIN_DATA` (`~/.codex/plugin-data/daybreak-autoreply/`), nunca en la raíz del plugin (la cache se reemplaza en updates).
- Nombre del plugin y repo: `daybreak-autoreply`. Versión 0.1.0. Windows-only (declarado en plugin.json y README).
- `ensure-daemon.ps1` SIEMPRE termina `exit 0` aunque falle todo por dentro (jamás romper un `SessionStart`).
- Git: commits tras cada task; etiqueta `v0.1.0` al final.

## Review Focus

1. **Hijo del hook muere al morir el hook/codex** (job object kill-on-close) → daemon ausente silencioso, el producto no hace nada. Test: spike del Task 1 mide heartbeat real ≥60 s tras cerrar Codex; Task 4 re-verifica con el daemon real. Si muere: mecanismo alternativo (tarea programada) ANTES de seguir.
2. **Update del plugin deja daemon huérfano** corriendo código viejo de una cache borrada → comportamiento fantasma. Test (Task 3): `Test-DaemonAlive` devuelve false cuando el PID vive pero su `CommandLine` ya no apunta al `watch.ps1` actual, y el flujo principal lo reemplaza.
3. **`PLUGIN_DATA` inaccesible/corrupto en el hook** → excepción que rompe el arranque de sesión. Test (Task 3): invocación con `-DataDir` ilegal termina `exit 0` sin output tóxico.
4. **Dos `SessionStart` concurrentes** (dos ventanas de Codex) → dos daemons enviando teclas duplicadas. Test (Task 3): segunda llamada con state vivo y misma ruta es no-op (un solo PID en state; el test crea la condición con un proceso real).
5. **`config.json` del usuario con typo tras instalar** → defaults silenciosos distintos de lo que el usuario creía. Ya cubierto por `Load-Config` (warn + merge); test de regresión en Task 4: config con clave inválida + clave buena conserva la buena y loguea warning.

---

### Task 1: Spike — supervivencia del hijo del hook

**Files:**
- Create: `spike/spawn-spike.ps1`
- Create: `spike/heartbeat.ps1`
- Create: `spike/README.md` (una línea: qué es y cómo limpiar)
- Temporary (fuera del repo, se borra al final del task): `~/.codex/hooks.json`

**Interfaces:**
- Produces: VEREDICTO del mecanismo de lanzamiento (`A: Start-Process directo sobrevive` | `B: requiere tarea programada`), escrito en el reporte del task y usado por Task 3. La técnica B documentada: `schtasks /create /f /tn DaybreakDaemon /tr "<cmd>" /sc onlogon` + `schtasks /run /tn DaybreakDaemon`.

- [ ] **Step 1: Escribir `heartbeat.ps1`**

Loop infinito: cada 1 s appendea `"$([DateTime]::UtcNow.ToString('o')) alive"` a `spike/heartbeat.log`; termina si existe `spike/stop-heartbeat.flag`.

- [ ] **Step 2: Escribir `spawn-spike.ps1`**

Lee stdin y lo descarta. `Start-Process` pwsh hidden ejecutando `heartbeat.ps1` con `-PassThru`; escribe el PID del hijo en `spike/spike-child.pid`; `exit 0`. Patrones del spike previo: sin rutas con espacios iniciales, `pwsh` resolverse solo ya está probado (v3 del spike funcionó con `cmd /c` + 8.3 — copiar esa forma exacta de comando si hace falta).

- [ ] **Step 3: Registrar y verificar localmente**

Crear `~/.codex/hooks.json` con `SessionStart` → `spawn-spike.ps1` (patrón comando idéntico al que ya funcionó: `cmd /c` + rutas 8.3 o sin espacios). Smoke local: pipear JSON falso a `spawn-spike.ps1` y verificar que `heartbeat.log` crece.

- [ ] **Step 4: Ronda de usuario + veredicto**

Usuario: abre sesión nueva de Codex → `/hooks` → trust → espera 10 s → CIERRA Codex del todo → avisa. Verificar: `heartbeat.log` sigue creciendo ≥60 s después del cierre → **VEREDICTO A**. Se detiene → probar mecanismo B (schtasks) en otra ronda igual → **VEREDICTO B**.

- [ ] **Step 5: Limpieza + commit**

Borrar `~/.codex/hooks.json`, crear `spike/stop-heartbeat.flag`, borrar `heartbeat.log`/`spike-child.pid`, quitar flag. Commit de los dos .ps1 + README del spike con el veredicto anotado.

---

### Task 2: Layout de plugin + reubicación del motor

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`
- Move: `watch.ps1` → `scripts/watch.ps1` (git mv)
- Move: `stop.ps1` → `scripts/stop.ps1` (git mv)
- Modify: `tests/run-tests.ps1`, `tests/e2e-dryrun.ps1` (rutas al motor)
- Create: `tests/test-plugin-structure.ps1`

**Interfaces:**
- Consumes: motor watchdog completo tal cual (funciones de su spec 2026-11-23).
- Produces: layout definitivo del repo-plugin que Tasks 3-6 asumen: `scripts/watch.ps1` con `param([string]$ConfigPath, [switch]$NoDaemon)`, `scripts/stop.ps1`, `hooks/hooks.json` con un único evento `SessionStart`, `.claude-plugin/plugin.json` con `"name": "daybreak-autoreply"`, `"version": "0.1.0"`.

- [ ] **Step 1: `git mv` y adaptar rutas en tests**

`git mv watch.ps1 stop.ps1 scripts/`. Actualizar en ambas suites cada referencia a `watch.ps1`/`stop.ps1` por `scripts/...` relativo a la raíz del repo.

- [ ] **Step 2: Escribir `tests/test-plugin-structure.ps1` (falla primero)**

Asserts: `plugin.json` parsea y tiene `name=daybreak-autoreply`, `version`, `description` no vacía; `hooks/hooks.json` parsea y tiene exactamente `SessionStart` con un handler `type=command` que referencia `ensure-daemon.ps1`; existen `scripts/watch.ps1`, `scripts/stop.ps1`, `commands/daybreak-{status,test,stop,start}.md`, `config.json` con las 3 claves de `responses` y `dry_run=false` (valores de Global Constraints).

- [ ] **Step 3: Verificar que falla**

Run: `pwsh -File tests/test-plugin-structure.ps1`
Expected: FAIL (no existe plugin.json ni commands).

- [ ] **Step 4: Crear manifest, hooks.json, mover config por defecto**

`plugin.json`: name/version/description/keywords (`daybreak`, `cyber_policy`, `autoreply`)/license MIT, nota Windows-only en description. `hooks/hooks.json`:
```json
{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/ensure-daemon.ps1\"", "timeout": 10, "statusMessage": "Daybreak: verificando daemon" } ] } ] } }
```
(patrón del plugin `codex@openai-codex` con `node "${CLAUDE_PLUGIN_ROOT}/..."`, probado en esta máquina; fallback documentado si el dev-install no arranca: forma `cmd /c` + 8.3 del spike v3).

- [ ] **Step 5: Suites completas + commit**

Run: `pwsh -File tests/run-tests.ps1; pwsh -File tests/e2e-dryrun.ps1; pwsh -File tests/test-plugin-structure.ps1`
Expected: las tres PASS (structure aún fallará por commands → sus archivos se crean en Task 5; para dejarlo verde YA, crear en este task los 4 `commands/*.md` como stubs mínimos con frontmatter válido y completarlos en Task 5).
Commit: `feat: layout plugin .claude-plugin + motor en scripts/`.

---

### Task 3: `ensure-daemon.ps1` con estado y flag (TDD)

**Files:**
- Create: `scripts/ensure-daemon.ps1`
- Modify: `tests/run-tests.ps1` (añadir bloque T8-T12)

**Interfaces:**
- Consumes: `scripts/watch.ps1` (lo lanza con `-ConfigPath "$DataDir\config.json"`); Task 1 (mecanismo de spawn elegido).
- Produces (Task 4 y 5 los consumen; firma exacta):
  - `Initialize-PluginData([string]$DataDir, [string]$DefaultConfigSrc) -> [string]` — crea `$DataDir\logs\`, copia el config default si no existe, devuelve la ruta del config del usuario.
  - `Test-DaemonAlive([int]$ProcId, [string]$WatchScriptPath) -> [bool]` — true solo si el proceso existe Y es pwsh Y su `CommandLine` contiene la ruta de `watch.ps1`.
  - `Invoke-EnsureDaemon([string]$DataDir, [string]$PluginRoot, [string]$WatchScript)` — flujo principal: respeta `disabled.flag`; lee `state.json` (`pid`, `script`); si vivo y misma ruta → no-op; si vivo con ruta distinta → `Stop-Process` y relanzar; si muerto → lanzar; guarda `state.json` nuevo.
  - Estado en archivos: `$DataDir\state.json`, `$DataDir\disabled.flag`, logs en `$DataDir\logs\watchdog.log`.

- [ ] **Step 1: Tests que fallan (añadir a run-tests.ps1)**

T8: `Initialize-PluginData` en temp crea config + logs y NO sobreescribe un config ya modificado (escribir clave centinela, re-invocar, la clave persiste).
T9: `Test-DaemonAlive` false para PID 999999; true para un pwsh real lanzado con `-File scripts/watch.ps1 -NoDaemon` (matarlo al final del test); false para un pwsh lanzado SIN watch.ps1.
T10: `Invoke-EnsureDaemon` con `disabled.flag` presente no crea state ni proceso.
T11: dos invocaciones seguidas (segunda con state vivo de la primera) no relanzan — el PID de `state.json` no cambia.
T12: invocación con `-DataDir` apuntando a ruta imposible (`Z:\no\existe\<random>`) termina exit 0 (script completo vía `pwsh -File`, assert `$LASTEXITCODE -eq 0`).

- [ ] **Step 2: Verificar fallo**

Run: `pwsh -File tests/run-tests.ps1`
Expected: FAIL en T8 (función no definida).

- [ ] **Step 3: Implementar `ensure-daemon.ps1`**

Param: `[string]$DataDir = $env:CLAUDE_PLUGIN_DATA`, `[string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT`, `[string]$WatchScript = "$PluginRoot\scripts\watch.ps1"`. Body completo envuelto en try/catch → `exit 0` siempre. Lanzamiento según VEREDICTO del Task 1 (A: `Start-Process pwsh -WindowStyle Hidden -PassThru`; B: schtasks). Dot-sourceable para tests (guard clause: solo correr main si `-File` invocation, no al dot-sourcear).

- [ ] **Step 4: Suites + commit**

Run: `pwsh -File tests/run-tests.ps1; pwsh -File tests/e2e-dryrun.ps1`
Expected: PASS (24+5 asserts + e2e).
Commit: `feat: ensure-daemon con state, flag persistente y saneo post-update`.

---

### Task 4: Motor adaptado a `PLUGIN_DATA` + E2E de integración

**Files:**
- Modify: `scripts/watch.ps1` (`Load-Config`: `log_file` relativo → resolver junto al config)
- Create: `tests/e2e-plugin.ps1`

**Interfaces:**
- Consumes: `Initialize-PluginData`, `Invoke-EnsureDaemon` de Task 3.
- Produces: E2E que prueba la cadena completa plugin→daemon→respuesta, ejecutable también por `/daybreak-test` (Task 5).

- [ ] **Step 1: Test de resolución de `log_file` (falla primero)**

En run-tests.ps1 (T13): config en temp con `log_file: "wd.log"` → tras `Load-Config`, `log_file` absoluta bajo el directorio del config; con ruta absoluta se respeta tal cual.

- [ ] **Step 2: Implementar en `Load-Config`**

Si `log_file` no está anclada a unidad (`^[A-Za-z]:\` o `\\`), `Join-Path (Split-Path $Path) $cfg.log_file`.

- [ ] **Step 3: `tests/e2e-plugin.ps1`**

Sandbox total en temp: `$DataDir`, config default copiado vía `Initialize-PluginData` y luego editado (`sessions_dir` → temp, `dry_run=true`, `delay_s=0`, `require_terminal_foreground=false`); `Invoke-EnsureDaemon`; esperar proceso; append del evento `event_msg` cyber_policy a un rollout sintético bajo el temp; assert: log en `$DataDir\logs\` contiene `DRYRUN` exactamente 1 (cooldown), `state.json` tiene PID vivo; matar daemon. Además (regresión Review Focus 5): config con clave basura + clave buena → warn en output y la buena conservada.

- [ ] **Step 4: Ejecutar + commit**

Run: `pwsh -File tests/e2e-plugin.ps1; pwsh -File tests/run-tests.ps1`
Expected: PASS todo.
Commit: `feat: motor resolve log junto a config + e2e integracion plugin`.

---

### Task 5: Slash commands, CLI y README

**Files:**
- Create: `scripts/daybreak-cli.ps1`
- Modify: `commands/daybreak-status.md`, `daybreak-test.md`, `daybreak-stop.md`, `daybreak-start.md` (completar stubs del Task 2)
- Create: `README.md` (sustituye al actual, orientado a plugin)
- Modify: `tests/run-tests.ps1` (bloque T14)

**Interfaces:**
- Consumes: `Invoke-EnsureDaemon`/estado de Task 3, `tests/e2e-plugin.ps1` de Task 4.
- Produces: `daybreak-cli.ps1` con subcomandos `status|start|stop|test` y param `-DataDir`/`-PluginRoot` (mismos defaults de Task 3); salida texto plano para que el command la renderice como tabla Markdown.

- [ ] **Step 1: Tests CLI que fallan (T14)**

`status` con `$DataDir` falso en temp imprime `NOT RUNNING` y exit 0; `stop` crea `disabled.flag` y no explota sin daemon; `start` borra el flag; `test -?` existe como subcomando (help sin explotar).

- [ ] **Step 2: Implementar `daybreak-cli.ps1`**

`status`: PID de state + `Test-DaemonAlive`, uptime, disabled, config resumen (responses), últimos 5 MATCH/SENT/DRYRUN/ABORT del log. `stop`: flag + `Stop-Process` si vivo. `start`: quitar flag + `Invoke-EnsureDaemon`. `test`: invoca `tests/e2e-plugin.ps1` y resume resultado. Siempre exit 0 con texto.

- [ ] **Step 3: Completar los 4 commands**

Formato referencia (`codex@openai-codex/commands/status.md`): frontmatter `description`, `disable-model-invocation: true`, `allowed-tools` para pwsh; body con `!`pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/daybreak-cli.ps1" status`` y una línea de instrucción de render (tabla compacta, sin prosa extra). `test` ejecuta el sandbox; `stop`/`start` muestran la salida del CLI tal cual.

- [ ] **Step 4: README**

Secciones: qué es (bloqueo Daybreak → envía tu texto solo), instalación (3 líneas `[marketplaces]` con URL git + `/plugins` + trust `/hooks`), aviso en negrita `dry_run=false` por defecto, tabla de config (13 claves), `/daybreak-*` commands, límites heredados (multi-pestaña WT, colisión ~500 ms, PS 7.4+ toast), actualización (re-trust), Windows-only, licencia.

- [ ] **Step 5: Suites + commit**

Run: `pwsh -File tests/run-tests.ps1; pwsh -File tests/test-plugin-structure.ps1`
Expected: PASS.
Commit: `feat: cli daybreak + slash commands + readme de instalacion`.

---

### Task 6: Dev-install local + E2E real con bloques

**Files:**
- Modify: `~/.codex/config.toml` (SOLO añadir `[marketplaces.daybreak-dev]` local apuntando al repo — misma clase de entrada que Codex escribe; documentado en README)
- Create: `docs/superpowers/plans/2026-11-24-daybreak-plugin-e2e-log.md` (bitácora de verificación)

**Interfaces:**
- Consumes: todo lo anterior.

- [ ] **Step 1: Registrar marketplace dev**

Añadir a config.toml: `[marketplaces.daybreak-dev]` `source_type = "local"` `source = '<ruta absoluta del repo>'`.

- [ ] **Step 2: Ronda de usuario — instalar**

Usuario: `/plugins` → pestaña daybreak-dev → Install `daybreak-autoreply` → `/hooks` → trust del hook SessionStart → abrir sesión nueva.

- [ ] **Step 3: Verificación automática post-instalación**

Asserts por PowerShell (sin tocar el TUI): `~/.codex/plugin-data/daybreak-autoreply/` contiene `config.json`, `logs/`, y `state.json` con PID vivo cuyo CommandLine apunta a la cache del plugin; `daybreak-cli.ps1 status` (invocado con esos env o rutas) imprime RUNNING. Si el daemon NO arrancó → aplicar fallback `cmd /c` + 8.3 en `hooks/hooks.json` (documentado en Task 2) y repetir ronda.

- [ ] **Step 4: Ronda de usuario — bloqueo real**

Usuario reproduce su bucle en la sesión moribunda (la que salta al instante). Verificar en `PLUGIN_DATA\logs\watchdog.log`: línea `MATCH cyber_policy` seguida de `SENT` (no DRYRUN — producción) con el texto `/goal resume`, y supresión por cooldown en el segundo bloqueo inmediato.

- [ ] **Step 5: Cierre**

Bitácora con evidencias, commit final, `git tag v0.1.0`. El repo queda listo para `git remote add origin <URL>` + push (lo hace el socio cuando quiera publicar).

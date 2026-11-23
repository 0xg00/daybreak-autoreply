# Daybreak Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Daemon PowerShell que detecta bloqueos `cyber_policy` de Codex CLI en los rollouts de sesión y auto-envía `/goal resume` (configurable) a la terminal con foco.

**Architecture:** Poll cada 1 s de archivos `rollout-*.jsonl` modificados bajo `sessions_dir` (por defecto `~/.codex/sessions`), lectura incremental con offsets por archivo y solapamiento de 256 chars; el match exige parse JSON real (`payload.error.codex_error_info -eq 'cyber_policy'`), no substring suelto. Inyección: verificación de proceso foreground contra lista de terminales, activación de la ventana padre del proceso codex como fallback, pegado por clipboard (restaurado) + Enter vía SendKeys. Control de ráfaga: cooldown + máx N disparos por ventana de tiempo + pausa.

**Tech Stack:** PowerShell 7 (pwsh), .NET FileSystemInfo/FileStream, WScript.Shell SendKeys, user32 P/Invoke (SetForegroundWindow), toast vía Windows Runtime (best-effort, sin módulos externos).

**Spec:** `docs/superpowers/specs/2026-11-23-daybreak-watchdog-design.md`

## Global Constraints

- PowerShell 7+ (`pwsh`), sin módulos externos (ni Pester: tests con script propio de asserts).
- NO modificar nada bajo `~/.codex/` — solo lectura de `sessions/`.
- Todas las rutas y valores default exactos de la spec: `send_text="/goal resume"`, `delay_s=3`, `cooldown_s=60`, `max_burst=3`, `burst_window_min=10`, `pause_after_limit_min=15`, `require_terminal_foreground=true`, `pattern='"codex_error_info":"cyber_policy'`.
- Mapa `responses` (código `codex_error_info` → texto): `cyber_policy`→`/goal resume`, `usage_limit_exceeded`→`/goal resume`, `context_window_exceeded`→`/compact`. Fallback global: `send_text="/goal resume"`. Censo real del socio: 3277 usage, 3013 cyber, 3 context.
- `dry_run=true` en config → registra la acción en log pero NO envía teclas (uso en tests E2E).
- Git: repo nuevo en la raíz del proyecto; commits tras cada task.
- Codifica archivos como UTF-8 sin BOM.

## Review Focus

1. **Patrón partido entre dos lecturas** (chunk boundary): el watcher lee bytes nuevos; el JSON del evento puede caer a caballo entre dos polls → mantener cola de 256 chars finales y pre-pendértela a la siguiente lectura. Test en Task 1.
2. **Falso positivo por cita**: la cadena `codex_error_info` puede aparecer dentro de un `input_text` de usuario (pega del JSON) → el match exige línea `event_msg` + `ConvertFrom-Json` + campo real. Test en Task 1.
3. **Dos sesiones escribiendo rollouts distintos a la vez** → offsets por archivo en hashtable. Test en Task 1.
4. **Foreground en proceso no-terminal** (Word, navegador) al disparar → jamás enviar teclas; esperar/activar. Test en Task 2.
5. **Sin ventana padre de codex localizable** (codex lanzado por otro proceso sin consola propia) → esperar hasta 120 s a que el foreground sea terminal; expirado, log y abort. Test en Task 2.

---

### Task 1: Núcleo de detección (config, lectura incremental, match, ráfaga, log)

**Files:**
- Create: `config.json`
- Create: `watch.ps1`
- Create: `tests/run-tests.ps1`

**Interfaces:**
- Produces (Task 2 y 3 las consumen):
  - `Load-Config([string]$Path) -> [hashtable]` — merge de defaults si falta el archivo o claves.
  - `Get-NewContent([string]$Path, [hashtable]$Offsets) -> [psobject]` con props `Content [string]`, `Offset [long]` — lee desde offset guardado, UTF-8, FileStream con FileShare ReadWrite|Delete; si el archivo se encogió (rotación), relee desde 0 y resetea offset.
  - `Find-BlockEvent([string]$Text, [string[]]$WatchCodes = @('cyber_policy','usage_limit_exceeded','context_window_exceeded')) -> [string]` — código `codex_error_info` encontrado o `$null`; por línea: solo si contiene `"type":"event_msg"` hace `ConvertFrom-Json` y devuelve `$_.payload.error.codex_error_info` si existe y está en `$WatchCodes`.
  - `Test-BurstAllowed([datetime]$Now, [System.Collections.Generic.List[datetime]]$History, [hashtable]$Cfg) -> [psobject]` con `Allowed [bool]`, `History [List[datetime]]` (cooldown + ventana ráfaga + pausa tras límite).
  - `Write-Log([string]$Msg, [hashtable]$Cfg)` — append a `log_file` con timestamp ISO.
  - Loop daemon (solo si no `-NoDaemon`); `param([string]$ConfigPath = "config.json", [switch]$NoDaemon)`: cada 1 s enumera `rollout-*.jsonl` con `LastWriteTime > $lastScan` bajo `sessions_dir` (recursivo), lee incremental, solapa 256 chars, y por match resuelve el texto `$cfg.responses[$codigo] ?? $cfg.send_text` y llama al callback `Invoke-Autorespond([string]$Text, [string]$Code, [hashtable]$Cfg)` (definido en Task 2; en Task 1 stub que solo loguea).

- [ ] **Step 1: `git init` + scaffold**

`git init`; crear `config.json` con las claves de Global Constraints (`sessions_dir` apuntando a `$env:USERPROFILE\.codex\sessions` expandido, `dry_run: true` inicial), `.gitignore` con `watchdog.log`.

- [ ] **Step 2: Escribir tests que fallan**

`tests/run-tests.ps1`: dot-source `watch.ps1 -NoDaemon` y asserts simples (`function Assert($cond, $name)` que acumula fallos y `exit 1` si alguno):

```powershell
# T1 overlap chunk boundary
$t = "x"*10; $r1 = @{ Content = '{"type":"event_msg","payl'; Offset = 27 }
# Find-BlockEvent debe devolver 'cyber_policy' al concatenar con la segunda mitad:
$full = $r1.Content + 'oad":{"type":"task_complete","error":{"message":"m","codex_error_info":"cyber_policy"}}}'
Assert ((Find-BlockEvent $full) -eq 'cyber_policy') 'block event detectado'
# T1b otros códigos vigilados
$usage = '{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"m","codex_error_info":"usage_limit_exceeded"}}}'
Assert ((Find-BlockEvent $usage) -eq 'usage_limit_exceeded') 'usage limit detectado'
# T2 falso positivo: cadena citada dentro de input_text de user
$fake = '{"type":"event_msg","payload":{"type":"user_message","content":[{"type":"input_text","text":"mira este codex_error_info\":\"cyber_policy citado"}]}}'
Assert ($null -eq (Find-BlockEvent $fake)) 'cita en input_text no dispara'
# T3 offsets dos archivos
$offs = @{}; $d = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wbtest-$(Get-Random)")
$f1 = Join-Path $d 'rollout-a.jsonl'; $f2 = Join-Path $d 'rollout-b.jsonl'
Set-Content $f1 'linea1'; Set-Content $f2 'linea2'
[void](Get-NewContent $f1 $offs); [void](Get-NewContent $f2 $offs)
Add-Content $f1 'linea3'; Add-Content $f2 'linea4'
Assert ((Get-NewContent $f1 $offs).Content -match 'linea3') 'offset por archivo f1'
Assert ((Get-NewContent $f2 $offs).Content -match 'linea4') 'offset por archivo f2'
# T4 burst: cooldown
$cfg = @{ cooldown_s = 60; max_burst = 3; burst_window_min = 10; pause_after_limit_min = 15 }
$h = [System.Collections.Generic.List[datetime]]::new(); $h.Add((Get-Date).AddSeconds(-10))
Assert (-not (Test-BurstAllowed (Get-Date) $h $cfg).Allowed) 'cooldown bloquea'
# T5 burst: límite de ráfaga
$h.Clear(); 1..3 | ForEach-Object { $h.Add((Get-Date).AddSeconds(-$_)) }
Assert (-not (Test-BurstAllowed (Get-Date) $h $cfg).Allowed) 'max_burst bloquea'
```

- [ ] **Step 3: Ejecutar tests — deben fallar**

Run: `pwsh -File tests/run-tests.ps1`
Expected: FAIL (`watch.ps1` no existe / comandos no definidos).

- [ ] **Step 4: Implementar `watch.ps1` (solo funciones de arriba + stub de `Invoke-Autorespond` + loop daemon tras `-NoDaemon` switch param)**

- [ ] **Step 5: Ejecutar tests — deben pasar**

Run: `pwsh -File tests/run-tests.ps1`
Expected: PASS (0 fallos, exit 0).

- [ ] **Step 6: Commit**

```bash
git add config.json watch.ps1 tests/run-tests.ps1 .gitignore
git commit -m "feat: nucleo detección cyber_policy en rollouts"
```

### Task 2: Inyección (foreground, ventana, clipboard, SendKeys, toast)

**Files:**
- Modify: `watch.ps1`
- Modify: `tests/run-tests.ps1`

**Interfaces:**
- Consumes: `Load-Config`, `Write-Log` de Task 1.
- Produces:
  - `Test-IsTerminalProcess([string]$ProcName, [string[]]$Terminals) -> [bool]` — comparación case-insensitive por nombre de proceso sin extensión.
  - `Get-CodexParentTerminal() -> [IntPtr]` (HWND o `[IntPtr]::Zero`) — enumera procesos cuyo nombre es `codex*` o `node` con línea de comando que contiene `codex`, sube al primer ancestro cuyo nombre esté en la lista de terminales, devuelve su `MainWindowHandle`.
  - `Invoke-Autorespond([string]$Text, [string]$Code, [hashtable]$Cfg)` — reemplaza el stub de 3 parámetros (así la llama el daemon en watch.ps1): `delay_s` sleep → foreground check → si no terminal y `require_terminal_foreground`: intentar `Get-CodexParentTerminal` + P/Invoke `SetForegroundWindow`; si sigue sin ser terminal, polling de foreground hasta 120 s; luego si `dry_run` → solo `Write-Log "DRYRUN"`, si no → clipboard backup (solo si `Get-Clipboard` no vacío), `Set-Clipboard $Text`, SendKeys `^v`, sleep 300 ms, `{ENTER}`, restaurar clipboard. Toast best-effort con try/catch silencioso.

- [ ] **Step 1: Tests que fallan (añadir a `tests/run-tests.ps1`)**

```powershell
# T6 no-terminal rechazado
$terms = @('WindowsTerminal','conhost','cmd','powershell','pwsh','Code','alacritty','wezterm-gui','mintty')
Assert (-not (Test-IsTerminalProcess 'WINWORD' $terms)) 'Word no es terminal'
Assert (Test-IsTerminalProcess 'WindowsTerminal' $terms) 'WT si es terminal'
Assert (Test-IsTerminalProcess 'Code' $terms) 'VS Code si es terminal'
# T7 dry_run no toca clipboard ni teclas: invocar con texto y verificar entrada de log
```

(T7a: en el test, `Invoke-Autorespond 'PRUEBA' ($cfg + @{dry_run=$true; require_terminal_foreground=$false; delay_s=0; log_file=$tmplog})` desde un pwsh cuyo propio proceso es `pwsh` — terminal válida — y assert de que `$tmplog` contiene `DRYRUN`.
T7b expiración sin terminal: `Invoke-Autorespond 'PRUEBA' ($cfg + @{dry_run=$true; require_terminal_foreground=$true; delay_s=0; foreground_wait_s=0; log_file=$tmplog2})` tras fingir foreground ajeno (monkey-patch del getter o param `-ForegroundProcName 'WINWORD'` para testabilidad) → log contiene `ABORT` y no `DRYRUN`.)

- [ ] **Step 2: Ejecutar — T6/T7 fallan**

Run: `pwsh -File tests/run-tests.ps1`
Expected: FAIL en `Test-IsTerminalProcess` no definida.

- [ ] **Step 3: Implementar inyección en `watch.ps1`**

SendKeys vía `New-Object -ComObject WScript.Shell`. P/Invoke mínimo con `Add-Type` para `SetForegroundWindow`/`GetForegroundWindow`/`GetWindowThreadProcessId`.

- [ ] **Step 4: Ejecutar tests — pasan**

Run: `pwsh -File tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add watch.ps1 tests/run-tests.ps1
git commit -m "feat: inyeccion foreground-safe con clipboard y sendkeys"
```

### Task 3: E2E simulado, stop.ps1, README

**Files:**
- Create: `stop.ps1`
- Create: `README.md`
- Modify: `config.json` (flip `dry_run: false` al final)
- Create: `tests/e2e-dryrun.ps1`

**Interfaces:**
- Consumes: `watch.ps1` completo con `-ConfigPath` param.

- [ ] **Step 1: Escribir `tests/e2e-dryrun.ps1`**

Crea `$env:TEMP\daybreak-e2e\sessions\2026\11\23\rollout-test.jsonl` vacío + `config.json` temporal con `sessions_dir` = ese dir, `dry_run=true`, `delay_s=0`, `require_terminal_foreground=false`, log a archivo temporal; arranca `pwsh -File watch.ps1 -ConfigPath …` como proceso; espera 2 s; hace `Add-Content` de la línea `event_msg` con `cyber_policy` (la del spec); espera 3 s; mata el proceso; assert: log contiene `DRYRUN` y una sola vez (dedup por cooldown).

- [ ] **Step 2: Ejecutar E2E — debe fallar primero si algo del wiring no existe**

Run: `pwsh -File tests/e2e-dryrun.ps1`
Expected: inicialmente FAIL o PASS; si FAIL, arreglar wiring en `watch.ps1` hasta PASS.

- [ ] **Step 3: `stop.ps1`**

`Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"` → mata los cuya `CommandLine` contiene `watch.ps1` (confirmación por `-WhatIf` primero; parámetro `-Force` para ejecutar).

- [ ] **Step 4: `README.md`**

Uso (arranque manual `pwsh -File watch.ps1` o minimized), tabla de claves de `config.json`, cómo probar con `dry_run`, límites conocidos (multi-pestaña WT, colisión con escritura del usuario), y cómo parar con `stop.ps1`.

- [ ] **Step 5: Flip `dry_run` a `false` + corrida final completa**

Run: `pwsh -File tests/run-tests.ps1; pwsh -File tests/e2e-dryrun.ps1`
Expected: ambos PASS.

- [ ] **Step 6: Commit**

```bash
git add stop.ps1 README.md tests/e2e-dryrun.ps1 config.json
git commit -m "feat: e2e dry-run, stop y documentacion"
```

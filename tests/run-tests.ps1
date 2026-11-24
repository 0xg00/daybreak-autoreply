# Tests Task 1 — nucleo de deteccion Daybreak Watchdog
# Run: pwsh -File tests/run-tests.ps1
# Requiere watch.ps1 (dot-source con -NoDaemon). Sin Pester: asserts propios.

$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Failures = 0

function Assert($cond, $name) {
    $script:Checks++
    if ($cond) {
        Write-Host "  ok   $name"
    }
    else {
        $script:Failures++
        Write-Host "  FAIL $name"
    }
}

# Dot-source del nucleo, sin arrancar el loop daemon
$watchPath = Join-Path $PSScriptRoot '..\scripts\watch.ps1'
. $watchPath -NoDaemon

Write-Host "== Task 1: nucleo de deteccion =="

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
# T2b M2: el pre-filtro tolera espacios alrededor de los dos puntos
$spaced = '{"type" : "event_msg","payload":{"type":"task_complete","error":{"message":"m","codex_error_info":"cyber_policy"}}}'
Assert ((Find-BlockEvent $spaced) -eq 'cyber_policy') 'pre-filtro tolera espacios en "type" : "event_msg"'
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

# T6 rotación: archivo encogido -> releer desde 0
$f3 = Join-Path $d 'rollout-c.jsonl'
Set-Content $f3 'linea-mas-larga'
[void](Get-NewContent $f3 $offs)
Set-Content $f3 'zz'
$rot = Get-NewContent $f3 $offs
Assert (($rot.Content -match 'zz') -and ($rot.Offset -eq 4)) 'rotacion relee desde 0'

# T7 Load-Config: merge de defaults si faltan claves o el archivo
$partialCfg = Join-Path $d 'config-partial.json'
[System.IO.File]::WriteAllText($partialCfg, '{ "cooldown_s": 5 }', [System.Text.UTF8Encoding]::new($false))
$merged = Load-Config $partialCfg
$missing = Load-Config (Join-Path $d 'no-existe.json')
Assert (($merged.cooldown_s -eq 5) -and ($merged.send_text -eq 'continue') -and ($merged.dry_run -eq $true)) 'Load-Config mergea defaults (fixture cooldown 5 prevailce, default fabrica continue)'
Assert (($merged.responses['context_window_exceeded'] -eq '/compact') -and ($merged.watch_codes.Count -eq 3)) 'Load-Config responses hashtable + watch_codes'
Assert (($missing.cooldown_s -eq 0) -and ($missing.delivery -eq 'queue') -and ($missing.sessions_dir -like '*\.codex\sessions')) 'Load-Config defaults si falta archivo (peticion socio: sin cooldown ni maximo)'

# T5b semantica 0 = sin limite (peticion del socio): nada suprimido jamas
$cfgFree = @{ cooldown_s = 0; max_burst = 0; burst_window_min = 10; pause_after_limit_min = 15 }
$hFree = [System.Collections.Generic.List[datetime]]::new()
1..10 | ForEach-Object { $hFree.Add((Get-Date).AddSeconds(-$_)) }  # 10 disparos hace <10 s
Assert (Test-BurstAllowed (Get-Date) $hFree $cfgFree).Allowed 'cooldown 0 + max 0 -> nunca suprime (bloques en la ventana de delay se envian)'

# T17 breaker por hilo (bucle bloqueo->continua->bloqueo en UNA sesion)
$cfgPT = @{ per_thread_max = 3; per_thread_window_min = 5; per_thread_pause_min = 15 }
$h1 = [System.Collections.Generic.List[datetime]]::new()
1..2 | ForEach-Object { $h1.Add((Get-Date).AddSeconds(-$_)) }
Assert (Test-ThreadAllowed (Get-Date) $h1 $cfgPT).Allowed 'T17a 2 envios al hilo -> permitido'
$h2 = [System.Collections.Generic.List[datetime]]::new()
1..3 | ForEach-Object { $h2.Add((Get-Date).AddSeconds(-$_)) }
Assert (-not (Test-ThreadAllowed (Get-Date) $h2 $cfgPT).Allowed) 'T17b 3 envios en <5 min -> pausa del hilo'
$h3 = [System.Collections.Generic.List[datetime]]::new()
1..3 | ForEach-Object { $h3.Add((Get-Date).AddMinutes(-16)) } ; $h3.Add((Get-Date).AddSeconds(-30))
Assert (Test-ThreadAllowed (Get-Date) $h3 $cfgPT).Allowed 'T17c fuera de ventana -> permitido'
$h4 = [System.Collections.Generic.List[datetime]]::new()
1..9 | ForEach-Object { $h4.Add((Get-Date).AddSeconds(-$_)) }
Assert (Test-ThreadAllowed (Get-Date) $h4 @{ per_thread_max = 0 }).Allowed 'T17d per_thread_max=0 -> desactivado'

# T18 defaults post-incidente: sin fallback sendkeys, breaker activo
Assert ($missing.sendkeys_fallback -eq $false) 'T18a sendkeys_fallback=false por defecto (nunca teclas a otra ventana)'
Assert ($missing.per_thread_max -eq 3) 'T18b per_thread_max=3 por defecto'

# T19 claves desconocidas se detectan (typo de dryrun no puede pasar en silencio)
$t19cfg = Join-Path $d 'config-typo.json'
[System.IO.File]::WriteAllText($t19cfg, '{"dryrun": true, "delai_s": 9, "cooldown_s": 5}', [System.Text.UTF8Encoding]::new($false))
$t19out = pwsh -NoProfile -Command ". '$watchPath' -NoDaemon; `$c = Load-Config '$t19cfg'; Write-Output ($c.__unknown_keys -join ',')"
Assert ("$t19out" -match 'dryrun') 'T19a typo dryrun reportado como desconocido'
Assert ("$t19out" -match 'delai_s') 'T19b typo delai_s reportado'
Assert ("$t19out" -notmatch 'cooldown_s') 'T19c clave valida no reportada'

# T20 Test-IsWatchProcess (identidad para kills, F3): pwsh ejecutando watch.ps1 -File
. (Join-Path $PSScriptRoot '..\scripts\ensure-daemon.ps1')
Assert (-not (Test-IsWatchProcess (Get-Process -Id $PID))) 'T20a el propio pwsh de tests (sin watch.ps1) no es proceso watch'
$t20p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-Command','Start-Sleep 20') -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 600
Assert (-not (Test-IsWatchProcess $t20p)) 'T20b pwsh ajeno (Start-Sleep) no es proceso watch'
Stop-Process -Id $t20p.Id -Force -ErrorAction SilentlyContinue
$t20cfg2 = Join-Path $d 't20-config.json'
[System.IO.File]::WriteAllText($t20cfg2, (@{ sessions_dir = $d; dry_run = $true; log_file = (Join-Path $d 't20.log') } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$t20w = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$watchPath,'-ConfigPath',$t20cfg2) -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 800
Assert (Test-IsWatchProcess $t20w) 'T20c pwsh real ejecutando watch.ps1 -File SI es proceso watch'
Stop-Process -Id $t20w.Id -Force -ErrorAction SilentlyContinue

# T8 Write-Log: append con timestamp ISO
$tmplog = Join-Path $d 'test-watchdog.log'
Write-Log 'evento de prueba' @{ log_file = $tmplog }
$logLine = Get-Content $tmplog -Raw
Assert (($logLine -match '\d{4}-\d{2}-\d{2}T') -and ($logLine -match 'evento de prueba')) 'Write-Log append con timestamp ISO'

# T9 burst: permitido tras cooldown con historia bajo el limite
$h.Clear(); $h.Add((Get-Date).AddMinutes(-2))
Assert ((Test-BurstAllowed (Get-Date) $h $cfg).Allowed) 'rafaga permite tras cooldown'

# --- Task 2: inyeccion (foreground, ventana, clipboard, SendKeys, toast) -------

# T6 no-terminal rechazado
$terms = @('WindowsTerminal','conhost','cmd','powershell','pwsh','Code','alacritty','wezterm-gui','mintty')
Assert (-not (Test-IsTerminalProcess 'WINWORD' $terms)) 'T6 Word no es terminal'
Assert (Test-IsTerminalProcess 'WindowsTerminal' $terms) 'T6 WT si es terminal'
Assert (Test-IsTerminalProcess 'Code' $terms) 'T6 VS Code si es terminal'
Assert (Test-IsTerminalProcess 'pwsh.exe' $terms) 'T6 nombre sin extension hace match'

# T7a dry_run no toca clipboard ni teclas: invocar con texto y verificar entrada de log
$t2dir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "wbtest2-$(Get-Random)")
$tmplog2 = Join-Path $t2dir 'dryrun.log'
$t7a = @{
    dry_run = $true; require_terminal_foreground = $false; delay_s = 0
    foreground_wait_s = 120; terminals = $terms; log_file = $tmplog2
}
$estadoA = Invoke-Autorespond 'PRUEBA' 'cyber_policy' $t7a
$logA = Get-Content $tmplog2 -Raw
Assert ($logA -match 'DRYRUN') 'T7a dry_run solo loguea DRYRUN'
Assert ($logA -notmatch 'AUTORESPOND code=') 'T7a no envia teclas ni clipboard'
Assert ($estadoA -eq 'DRYRUN') 'T7a estado devuelto DRYRUN (I2)'

# T7b expiracion sin terminal: foreground ajeno (override -ForegroundProcName)
# + foreground_wait_s=0 -> ABORT y no DRYRUN
$tmplog3 = Join-Path $t2dir 'abort.log'
$t7b = @{
    dry_run = $true; require_terminal_foreground = $true; delay_s = 0
    foreground_wait_s = 0; terminals = $terms; log_file = $tmplog3
}
$estadoB = Invoke-Autorespond 'PRUEBA' 'cyber_policy' $t7b -ForegroundProcName 'WINWORD'
$logB = Get-Content $tmplog3 -Raw
Assert ($logB -match 'ABORT') 'T7b sin terminal tras espera -> ABORT'
Assert ($logB -notmatch 'DRYRUN') 'T7b ABORT no llega a DRYRUN'
Assert ($estadoB -eq 'ABORT') 'T7b estado devuelto ABORT (I2)'

# --- Task 3: ensure-daemon (T8-T12) -----------------------------------------
Write-Host "== Task 3: ensure-daemon =="
$ensurePath = Join-Path $PSScriptRoot '..\scripts\ensure-daemon.ps1'
. $ensurePath   # dot-source: define funciones, NO corre main (guard de invocacion)

$edDir = Join-Path $env:TEMP "edtest-$(Get-Random)"
[void](New-Item -ItemType Directory -Force -Path $edDir)
$defaultCfg = Join-Path $PSScriptRoot '..\config.json'

# T8 Initialize-PluginData: crea config + logs; NO sobreescribe config del usuario
$cfgUser = Initialize-PluginData $edDir $defaultCfg
Assert (Test-Path $cfgUser) 'T8a crea config de usuario'
Assert (Test-Path (Join-Path $edDir 'logs')) 'T8b crea dir logs'
($cfg = Get-Content $cfgUser -Raw -Encoding utf8 | ConvertFrom-Json) | Out-Null
Assert ($cfg.dry_run -eq $false) 'T8c config copiado conserva dry_run=false'
# mutar clave centinela y re-inicializar: debe persistir
$j = Get-Content $cfgUser -Raw -Encoding utf8 | ConvertFrom-Json
$j | Add-Member -NotePropertyName sentinela -NotePropertyValue 'mia' -Force
[System.IO.File]::WriteAllText($cfgUser, ($j | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
[void](Initialize-PluginData $edDir $defaultCfg)
$j2 = Get-Content $cfgUser -Raw -Encoding utf8 | ConvertFrom-Json
Assert ($j2.sentinela -eq 'mia') 'T8d NO sobreescribe config ya existente'

# T9 Test-DaemonAlive
Assert (-not (Test-DaemonAlive 999999 'X:\nada\watch.ps1')) 'T9a PID inexistente -> false'
$wsPath = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\watch.ps1')).Path
# daemon real y VIVO: loop contra un sessions_dir temporal vacio (inofensivo)
$t9dir = Join-Path $env:TEMP "t9-$(Get-Random)"; [void](New-Item -ItemType Directory -Force $t9dir)
$t9cfg = Join-Path $t9dir 'config.json'
[System.IO.File]::WriteAllText($t9cfg, (@{ sessions_dir = $t9dir; dry_run = $true; log_file = (Join-Path $t9dir 'wd.log') } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$realDaemon = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $wsPath, '-ConfigPath', $t9cfg) -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 900
Assert (Test-DaemonAlive $realDaemon.Id $wsPath) 'T9b pwsh real con watch.ps1 -> true'
$otro = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 30') -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 600
Assert (-not (Test-DaemonAlive $otro.Id $wsPath)) 'T9c pwsh SIN watch.ps1 -> false (saneo post-update)'
Stop-Process -Id $otro.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $realDaemon.Id -Force -ErrorAction SilentlyContinue
try { Remove-Item $t9dir -Recurse -Force -ErrorAction Stop } catch { }

# T10 disabled.flag respeta: no crea state ni proceso
[void](Invoke-EnsureDaemon $edDir $PSScriptRoot $wsPath)  # arranca uno para tener base
Start-Sleep -Milliseconds 600
$state1 = Get-Content (Join-Path $edDir 'state.json') -Raw | ConvertFrom-Json
Stop-Process -Id $state1.pid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Remove-Item (Join-Path $edDir 'state.json') -Force   # partir de cero: el flag debe impedir CREAR
New-Item -ItemType File -Path (Join-Path $edDir 'disabled.flag') -Force | Out-Null
[void](Invoke-EnsureDaemon $edDir $PSScriptRoot $wsPath)
Start-Sleep -Milliseconds 600
Assert (-not (Test-Path (Join-Path $edDir 'state.json'))) 'T10a disabled.flag -> no crea state'
$procsFlag = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape((Join-Path $edDir 'config.json')) })
Assert ($procsFlag.Count -eq 0) 'T10b disabled.flag -> no lanza proceso'
Remove-Item (Join-Path $edDir 'disabled.flag') -Force

# T11 dos invocaciones seguidas con daemon vivo -> mismo PID (no duplica)
[void](Invoke-EnsureDaemon $edDir $PSScriptRoot $wsPath)
Start-Sleep -Milliseconds 800
$stateA = Get-Content (Join-Path $edDir 'state.json') -Raw | ConvertFrom-Json
[void](Invoke-EnsureDaemon $edDir $PSScriptRoot $wsPath)
Start-Sleep -Milliseconds 400
$stateB = Get-Content (Join-Path $edDir 'state.json') -Raw | ConvertFrom-Json
Assert ($stateA.pid -eq $stateB.pid) 'T11 segunda invocacion no relanza (mismo PID)'
Assert (Test-DaemonAlive $stateB.pid $wsPath) 'T11 daemon vivo tras doble ensure'
Stop-Process -Id $stateB.pid -Force -ErrorAction SilentlyContinue

# T12 DataDir imposible -> exit 0 (invocacion como -File, proceso aparte)
$bad = 'Z:\no\existe\ed-' + (Get-Random)
$proc12 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $ensurePath, '-DataDir', $bad) -Wait -PassThru -WindowStyle Hidden
Assert ($proc12.ExitCode -eq 0) 'T12 DataDir imposible termina exit 0'

# T13 log_file relativo se resuelve junto al config; absoluto se respeta
$t13dir = Join-Path $env:TEMP "t13-$(Get-Random)"; [void](New-Item -ItemType Directory -Force $t13dir)
$c1 = Join-Path $t13dir 'config.json'
[System.IO.File]::WriteAllText($c1, (@{ log_file = 'wd.log'; sessions_dir = $t13dir } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$cfgT13 = Load-Config $c1
Assert ($cfgT13.log_file -eq (Join-Path $t13dir 'wd.log')) 'T13a log_file relativo -> junto al config'
$absLog = Join-Path $t13dir 'abs.log'
[System.IO.File]::WriteAllText($c1, (@{ log_file = $absLog; sessions_dir = $t13dir } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$cfgT13b = Load-Config $c1
Assert ($cfgT13b.log_file -eq $absLog) 'T13b log_file absoluto se respeta'
try { Remove-Item $t13dir -Recurse -Force -ErrorAction Stop } catch { }

# T14 CLI (Task 5)
$cliPath = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\daybreak-cli.ps1' -ErrorAction SilentlyContinue)).Path
if (-not $cliPath) { $cliPath = Join-Path $PSScriptRoot '..\scripts\daybreak-cli.ps1' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$t14dir = Join-Path $env:TEMP "t14-$(Get-Random)"; [void](New-Item -ItemType Directory -Force $t14dir)
# config sandbox PRE-creado para que 'start' nunca toque sessions reales
$t14sess = Join-Path $t14dir 'sess'; [void](New-Item -ItemType Directory -Force $t14sess)
[System.IO.File]::WriteAllText((Join-Path $t14dir 'config.json'), (@{ sessions_dir = $t14sess; dry_run = $true; delay_s = 0; require_terminal_foreground = $false; log_file = 'logs/watchdog.log' } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

$stOut = pwsh -NoProfile -File $cliPath status -DataDir $t14dir -PluginRoot $repoRoot
Assert ("$stOut" -match 'NOT RUNNING') 'T14a status sin daemon -> NOT RUNNING'
Assert ($LASTEXITCODE -eq 0) 'T14b status exit 0'

$null = pwsh -NoProfile -File $cliPath stop -DataDir $t14dir -PluginRoot $repoRoot
Assert (Test-Path (Join-Path $t14dir 'disabled.flag')) 'T14c stop crea disabled.flag'
Assert ($LASTEXITCODE -eq 0) 'T14d stop exit 0 sin daemon'

$null = pwsh -NoProfile -File $cliPath start -DataDir $t14dir -PluginRoot $repoRoot
Start-Sleep -Milliseconds 900
Assert (-not (Test-Path (Join-Path $t14dir 'disabled.flag'))) 'T14e start quita disabled.flag'
Assert (Test-Path (Join-Path $t14dir 'state.json')) 'T14f start arranca daemon (state.json)'
$t14state = Get-Content (Join-Path $t14dir 'state.json') -Raw | ConvertFrom-Json
Stop-Process -Id ([int]$t14state.pid) -Force -ErrorAction SilentlyContinue

$helpOut = pwsh -NoProfile -File $cliPath
Assert ("$helpOut" -match 'test') 'T14g usage documenta subcomando test'
Assert ($LASTEXITCODE -eq 0) 'T14h sin args exit 0 (usage)'

# T21 cli set: cambia el texto de respuesta y NO toca /compact
$t21dir = Join-Path $env:TEMP "t21-$(Get-Random)"; [void](New-Item -ItemType Directory -Force $t21dir)
$t21sess = Join-Path $t21dir 'sess'; [void](New-Item -ItemType Directory -Force $t21sess)
[System.IO.File]::WriteAllText((Join-Path $t21dir 'config.json'), (@{ sessions_dir = $t21sess; dry_run = $true; send_text = 'continua'; responses = @{ cyber_policy = 'continua'; usage_limit_exceeded = 'continua'; context_window_exceeded = '/compact' }; log_file = 'logs/watchdog.log' } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
$setOut = pwsh -NoProfile -File $cliPath set ' sigue con ello ' -DataDir $t21dir -PluginRoot $repoRoot
Assert ($LASTEXITCODE -eq 0) 'T21a set exit 0'
$t21c = Get-Content (Join-Path $t21dir 'config.json') -Raw -Encoding utf8 | ConvertFrom-Json
Assert ($t21c.send_text -eq 'sigue con ello') 'T21b send_text actualizado (trim)'
Assert ($t21c.responses.cyber_policy -eq 'sigue con ello') 'T21c cyber_policy actualizado'
Assert ($t21c.responses.usage_limit_exceeded -eq 'sigue con ello') 'T21d usage_limit actualizado'
Assert ($t21c.responses.context_window_exceeded -eq '/compact') 'T21e /compact intacto'
$getOut = pwsh -NoProfile -File $cliPath set -DataDir $t21dir -PluginRoot $repoRoot
Assert ("$getOut" -match 'sigue con ello') 'T21f set sin args muestra el texto actual'
$badSet = pwsh -NoProfile -File $cliPath set '   ' -DataDir $t21dir -PluginRoot $repoRoot
Assert ("$badSet" -match 'uso|texto|vac') 'T21g set vacio -> ayuda, no rompe'
try { Remove-Item $t21dir -Recurse -Force -ErrorAction Stop } catch { }
try { Remove-Item $t14dir -Recurse -Force -ErrorAction Stop } catch { }

# T15 Get-RolloutThreadIds (Task 6 adenda: entrega por codex queue)
Write-Host "== Task 6 adenda: queue delivery =="
$dual = Get-RolloutThreadIds 'rollout-2026-11-23T19-23-57-01a208d7-fd7f-7a43-aeb3-78f1b969133d_01a209a6-833a-7ac1-bb80-638a8bd7d82c.jsonl'
Assert ($dual.Count -eq 2) 'T15a extrae 2 UUIDs del nombre dual'
Assert ($dual[0] -eq '01a208d7-fd7f-7a43-aeb3-78f1b969133d') 'T15b primer UUID (sesion)'
Assert ($dual[1] -eq '01a209a6-833a-7ac1-bb80-638a8bd7d82c') 'T15c segundo UUID (thread)'
$single = @(Get-RolloutThreadIds 'rollout-2026-11-24T19-51-07-01a20ee5-bdae-7450-ae9b-dae751c06dbf.jsonl')
Assert ($single.Count -eq 1 -and $single[0] -eq '01a20ee5-bdae-7450-ae9b-dae751c06dbf') 'T15d nombre simple -> 1 UUID'
Assert (@(Get-RolloutThreadIds 'rollout-sin-uuid.jsonl').Count -eq 0) 'T15e sin UUID -> vacio'

# T16 Invoke-QueueDelivery con doble de proceso en el borde del CLI
$t16dir = Join-Path $env:TEMP "t16-$(Get-Random)"; [void](New-Item -ItemType Directory -Force $t16dir)
# falso codex: exit 0 + linea "Queued message <id> for thread <t>"
$fake = Join-Path $t16dir 'fake-codex.cmd'
Set-Content $fake "@echo off`r`necho Queued message fake-msg-1 for thread %1`r`nexit /b 0" -Encoding Ascii
# falso codex fallido: exit 1
$fakeBad = Join-Path $t16dir 'fakebad-codex.cmd'
Set-Content $fakeBad "@echo off`r`necho Error: thread not found`r`nexit /b 1" -Encoding Ascii
$t16log = Join-Path $t16dir 'q.log'
$t16cfg = @{ log_file = $t16log }
$stQ = Invoke-QueueDelivery '/goal resume' 'cyber_policy' @('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002') ($t16cfg + @{ codex_exe = $fake })
Assert ($stQ -eq 'SENT') 'T16a queue con doble exit-0 -> SENT'
$qlog = Get-Content $t16log -Raw
Assert ($qlog -match 'QUEUE_SENT') 'T16b loguea QUEUE_SENT'
Assert ($qlog -match 'aaaaaaaa-0000') 'T16c loguea el thread usado (primero que funciona)'
$stBad = Invoke-QueueDelivery '/goal resume' 'cyber_policy' @('cccccccc-0000-0000-0000-000000000003') ($t16cfg + @{ codex_exe = $fakeBad })
Assert ($stBad -eq 'ERROR') 'T16d todos fallan -> ERROR (fallback a sendkeys lo decide el caller)'
$t16log2 = Get-Content $t16log -Raw
Assert ($t16log2 -match 'QUEUE_FAILED') 'T16e loguea QUEUE_FAILED con salida'
try { Remove-Item $t16dir -Recurse -Force -ErrorAction Stop } catch { }

try { Remove-Item $edDir -Recurse -Force -ErrorAction Stop } catch { }

# Limpieza y resumen
try { Remove-Item $d -Recurse -Force -ErrorAction Stop } catch { }
try { Remove-Item $t2dir -Recurse -Force -ErrorAction Stop } catch { }
Write-Host "== Resultado: $($script:Checks - $script:Failures)/$script:Checks ok, $script:Failures fallos =="
if ($script:Failures -gt 0) { exit 1 }
exit 0

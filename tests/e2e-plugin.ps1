# E2E integracion plugin: Initialize-PluginData -> Invoke-EnsureDaemon ->
# daemon real -> evento cyber_policy -> DRYRUN en PLUGIN_DATA\logs\watchdog.log.
# Sandbox TOTAL en temp: nunca toca ~/.codex/sessions. Reusa el patron de
# tests/e2e-dryrun.ps1. Run: pwsh -File tests/e2e-plugin.ps1
$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Failures = 0

function Assert($cond, $name) {
    $script:Checks++
    if ($cond) { Write-Host "  ok   $name" } else { $script:Failures++; Write-Host "  FAIL $name" }
}

$repo    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root    = Join-Path $env:TEMP "daybreak-plugin-e2e-$(Get-Random)"
$sessions = Join-Path $root 'sessions\2026\11\24'
$pdata = Join-Path $root 'data'
[void](New-Item -ItemType Directory -Force -Path $sessions)
[void](New-Item -ItemType Directory -Force -Path $pdata)

. (Join-Path $repo 'scripts\ensure-daemon.ps1')

$eventLine = '{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Daybreak","codex_error_info":"cyber_policy"}}}'
$rollout   = Join-Path $sessions 'rollout-e2e.jsonl'
$wdLog     = Join-Path $pdata 'logs\watchdog.log'

try {
    # 1) config de usuario ANTES del primer ensure: Initialize-PluginData debe
    #    respetarlo (no sobreescribir con el default del repo)
    $cfg = @{
        sessions_dir                = $sessions
        log_file                    = 'logs/watchdog.log'
        dry_run                     = $true
        delivery                    = 'sendkeys'   # esta suite prueba el motor legacy end-to-end
        delay_s                     = 0
        require_terminal_foreground = $false
        cooldown_s                  = 60
    }
    [System.IO.File]::WriteAllText((Join-Path $pdata 'config.json'), ($cfg | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

    # 2) ensure arranca el daemon con esa config
    $wsPath = Join-Path $repo 'scripts\watch.ps1'
    $null = Invoke-EnsureDaemon -DataDir $pdata -PluginRoot $repo -WatchScript $wsPath
    Start-Sleep -Seconds 2

    $state = Get-Content (Join-Path $pdata 'state.json') -Raw | ConvertFrom-Json
    Assert ($state.pid) 'E1 state.json con pid'
    Assert (Test-DaemonAlive ([int]$state.pid) $wsPath) 'E2 daemon vivo ejecutando watch.ps1'

    # 3) rollout NUEVO (post-arranque) + evento: exactamente 1 DRYRUN
    [System.IO.File]::WriteAllText($rollout, '', [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 1500   # dejar que el daemon lo descubra vacio
    Add-Content -LiteralPath $rollout -Value $eventLine -Encoding utf8
    Start-Sleep -Seconds 3

    Assert (Test-Path $wdLog) 'E3 log en PLUGIN_DATA\logs\watchdog.log'
    $logText = Get-Content $wdLog -Raw
    $dryruns = ([regex]::Matches($logText, 'DRYRUN')).Count
    Assert ($dryruns -eq 1) "E4 un DRYRUN exacto (actual: $dryruns)"

    # 4) segunda entrega inmediata -> suprimida por cooldown (sigue 1)
    Add-Content -LiteralPath $rollout -Value $eventLine -Encoding utf8
    Start-Sleep -Seconds 2
    $logText2 = Get-Content $wdLog -Raw
    $dryruns2 = ([regex]::Matches($logText2, 'DRYRUN')).Count
    Assert ($dryruns2 -eq 1) "E5 cooldown suprime el segundo disparo (actual: $dryruns2)"

    # 5) segunda invocacion de ensure con daemon vivo: no-op (mismo PID)
    $null = Invoke-EnsureDaemon -DataDir $pdata -PluginRoot $repo -WatchScript $wsPath
    Start-Sleep -Milliseconds 500
    $state2 = Get-Content (Join-Path $pdata 'state.json') -Raw | ConvertFrom-Json
    Assert ($state2.pid -eq $state.pid) 'E6 ensure repetido no duplica daemon'

    # 6) regresion RF5: config con clave basura + clave buena -> warn y conserva la buena
    $cfgBad = @{
        sessions_dir = $sessions
        clave_basura_total = 'x'
        cooldown_s  = 77
        log_file    = $wdLog
    }
    $cbPath = Join-Path $root 'cfg-bad.json'
    [System.IO.File]::WriteAllText($cbPath, ($cfgBad | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $out = pwsh -NoProfile -Command ". (Join-Path '$repo' 'scripts\watch.ps1') -NoDaemon; `$c = Load-Config '$cbPath'; Write-Output (`$c.cooldown_s)"
    Assert ("$out" -match '77') "E7 config con clave basura conserva las buenas (cooldown_s=77, actual: $out)"

    # E8 portabilidad: DataDir CON ESPACIOS arranca daemon (quoting del spawn)
    $spDir = Join-Path $root 'data con espacios raros'
    [void](New-Item -ItemType Directory -Force $spDir)
    $spCfg = @{ sessions_dir = (Join-Path $root 'sess'); dry_run = $true; delay_s = 0; require_terminal_foreground = $false; log_file = 'logs/watchdog.log' }
    [System.IO.File]::WriteAllText((Join-Path $spDir 'config.json'), ($spCfg | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-EnsureDaemon -DataDir $spDir -PluginRoot $repo -WatchScript $wsPath
    Start-Sleep -Seconds 2
    $spState = Get-Content (Join-Path $spDir 'state.json') -Raw | ConvertFrom-Json
    Assert (Test-DaemonAlive ([int]$spState.pid) $wsPath) 'E8 daemon vivo con DataDir con espacios'
    Assert (Test-Path (Join-Path $spDir 'logs\watchdog.log')) 'E8b daemon leyo su config (log creado junto al config)'
    Stop-Process -Id ([int]$spState.pid) -Force -ErrorAction SilentlyContinue

    # E9 identidad de kill: state apuntando a un proceso INOCENTE no lo mata
    $innocent = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-Command','Start-Sleep 25') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    [System.IO.File]::WriteAllText((Join-Path $pdata 'state.json'), (@{ pid = $innocent.Id; script = 'X:\viejo\watch.ps1'; started = (Get-Date -Format o) } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-EnsureDaemon -DataDir $pdata -PluginRoot $repo -WatchScript $wsPath
    Start-Sleep -Seconds 2
    Assert (Get-Process -Id $innocent.Id -ErrorAction SilentlyContinue) 'E9a proceso inocente (PID reutilizado) NO recibe Stop-Process'
    $st9 = Get-Content (Join-Path $pdata 'state.json') -Raw | ConvertFrom-Json
    Assert ($st9.pid -ne $innocent.Id) 'E9b state ahora apunta al daemon nuevo'
    Stop-Process -Id $innocent.Id -Force -ErrorAction SilentlyContinue
    if ($st9.pid) { Stop-Process -Id ([int]$st9.pid) -Force -ErrorAction SilentlyContinue }

    # E10 concurrencia: dos ensures en paralelo -> UN solo daemon para este DataDir
    $ccDir = Join-Path $root 'data cc'
    [void](New-Item -ItemType Directory -Force $ccDir)
    [System.IO.File]::WriteAllText((Join-Path $ccDir 'config.json'), ($spCfg | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $ensureP = Join-Path $repo 'scripts\ensure-daemon.ps1'
    $j1 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$ensureP,'-DataDir',('"{0}"' -f $ccDir),'-PluginRoot',$repo,'-WatchScript',$wsPath) -WindowStyle Hidden -PassThru
    $j2 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$ensureP,'-DataDir',('"{0}"' -f $ccDir),'-PluginRoot',$repo,'-WatchScript',$wsPath) -WindowStyle Hidden -PassThru
    Wait-Process -Id $j1.Id, $j2.Id -Timeout 20 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $ccProcs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape((Join-Path $ccDir 'config.json')) })
    Assert ($ccProcs.Count -eq 1) "E10 dos SessionStart concurrentes -> un solo daemon (hay $($ccProcs.Count))"
    foreach ($cp in $ccProcs) { Stop-Process -Id $cp.ProcessId -Force -ErrorAction SilentlyContinue }

    # E11 hot-reload: cambiar send_text con el daemon vivo -> el siguiente disparo usa el texto nuevo
    $c11 = Get-Content (Join-Path $pdata 'config.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $c11 | Add-Member -NotePropertyName send_text -NotePropertyValue 'recargado' -Force
    if (-not $c11.responses) { $c11 | Add-Member -NotePropertyName responses -NotePropertyValue ([pscustomobject]@{}) -Force }
    $c11.responses | Add-Member -NotePropertyName cyber_policy -NotePropertyValue 'recargado' -Force
    $c11.cooldown_s = 1
    [System.IO.File]::WriteAllText((Join-Path $pdata 'config.json'), ($c11 | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Seconds 3   # cooldown 1s + reload por iteracion
    Add-Content -LiteralPath $rollout -Value $eventLine -Encoding utf8
    Start-Sleep -Seconds 3
    $log11 = Get-Content $wdLog -Raw
    Assert ($log11 -match 'texto=recargado') 'E11 daemon recarga config en caliente (texto nuevo usado sin reinicio)'
}
finally {
    if ($state -and $state.pid) { Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
    try { Remove-Item $root -Recurse -Force -ErrorAction Stop } catch { }
}

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "FAIL E2E plugin: $($script:Failures) de $($script:Checks) asserts fallaron" -ForegroundColor Red
    exit 1
}
Write-Host "== Resultado E2E plugin: $($script:Checks)/$($script:Checks) ok, 0 fallos ==" -ForegroundColor Green
exit 0


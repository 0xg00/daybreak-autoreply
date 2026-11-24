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


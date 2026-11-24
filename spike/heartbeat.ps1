# Spike supervivencia: hijo heartbeat. Escribe un latido por segundo en
# spike/heartbeat.log hasta que exista spike/stop-heartbeat.flag.
$ErrorActionPreference = 'SilentlyContinue'
$dir = $PSScriptRoot
$log = Join-Path $dir 'heartbeat.log'
$stop = Join-Path $dir 'stop-heartbeat.flag'
while (-not (Test-Path -LiteralPath $stop)) {
    Add-Content -LiteralPath $log -Value "$([DateTime]::UtcNow.ToString('o')) alive pid=$PID"
    Start-Sleep -Seconds 1
}

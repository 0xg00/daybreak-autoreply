# daybreak-cli.ps1 — subcomandos que usan los slash commands del plugin:
#   status | start | stop | test
# Salida texto plano (para render Markdown en Codex). SIEMPRE exit 0.
param(
    [Parameter(Position = 0)][string]$Command = '',
    [string]$DataDir = $env:CLAUDE_PLUGIN_DATA,
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT
)

# capturar ANTES del dot-source: ensure-daemon.ps1 tiene param() que
# reasigna $DataDir/$PluginRoot a sus defaults al dot-sourcearse
$dd = $DataDir; $pr = $PluginRoot
if (-not $dd) { $dd = Join-Path $env:USERPROFILE '.codex\plugin-data\daybreak-autoreply' }
if (-not $pr) { $pr = Split-Path (Split-Path $PSScriptRoot) }

. (Join-Path $PSScriptRoot 'ensure-daemon.ps1')

$wsPath = Join-Path $pr 'scripts\watch.ps1'
$statePath = Join-Path $dd 'state.json'
$flagPath = Join-Path $dd 'disabled.flag'
$wdLog = Join-Path $dd 'logs\watchdog.log'

function Get-CliState {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return Get-Content $statePath -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
}

function Show-Usage {
    "daybreak-autoreply CLI"
    "  status   estado del daemon (PID, uptime, config, ultimos disparos)"
    "  stop     apagado persistente (flag disabled) + mata el daemon"
    "  start    reactiva (quita flag) y asegura el daemon"
    "  test     E2E sandbox del motor (DRYRUN, sin teclas reales)"
}

switch ($Command) {
    'status' {
        $disabled = Test-Path -LiteralPath $flagPath
        $st = Get-CliState
        $running = $false
        if ($st) { $running = Test-DaemonAlive ([int]$st.pid) $wsPath }
        if ($running) {
            $up = try { ((Get-Date) - [datetime]$st.started).ToString('dd\.hh\:mm\:ss') } catch { '?' }
            "RUNNING pid=$($st.pid) uptime=$up started=$($st.started)"
        } else {
            "NOT RUNNING"
        }
        if ($disabled) { "disabled=true (flag presente; /daybreak-start para reactivar)" }
        $cfgPath = Join-Path $dd 'config.json'
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $c = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
                $map = @(); foreach ($p in $c.responses.PSObject.Properties) { $map += "$($p.Name) -> $($p.Value)" }
                "config: dry_run=$($c.dry_run) delay_s=$($c.delay_s) cooldown_s=$($c.cooldown_s)"
                "responses: " + ($map -join '; ')
            } catch { "config: (ilegible: $($_.Exception.Message))" }
        }
        if (Test-Path -LiteralPath $wdLog) {
            "--- ultimos eventos ---"
            Get-Content $wdLog -Tail 60 | Where-Object { $_ -match 'MATCH|SENT|DRYRUN|ABORT|ERROR' } | Select-Object -Last 5
        }
    }
    'stop' {
        New-Item -ItemType File -Path $flagPath -Force | Out-Null
        $st = Get-CliState
        if ($st -and $st.pid) {
            if (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue) {
                Stop-Process -Id ([int]$st.pid) -Force -ErrorAction SilentlyContinue
                "daemon (pid $($st.pid)) detenido."
            }
        }
        "daybreak-autoreply desactivado de forma persistente."
        "se reactivara solo con /daybreak-start (el flag sobrevive a sesiones nuevas)."
    }
    'start' {
        Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
        try { $null = Invoke-EnsureDaemon -DataDir $dd -PluginRoot $pr -WatchScript $wsPath } catch { }
        Start-Sleep -Milliseconds 800
        $st = Get-CliState
        if ($st -and (Test-DaemonAlive ([int]$st.pid) $wsPath)) { "RUNNING pid=$($st.pid)" }
        else { "arrancado (verifica con status)" }
    }
    'test' {
        $e2e = Join-Path $pr 'tests\e2e-plugin.ps1'
        if (Test-Path -LiteralPath $e2e) {
            pwsh -NoProfile -File $e2e
            "exit=$LASTEXITCODE"
        } else { "no se encuentra tests/e2e-plugin.ps1 bajo $pr" }
    }
    default {
        Show-Usage
    }
}
exit 0

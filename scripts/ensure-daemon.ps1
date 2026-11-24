# ensure-daemon.ps1 — hook SessionStart del plugin daybreak-autoreply.
# Garantiza un daemon watch.ps1 vivo con estado en PLUGIN_DATA:
#   - respeta disabled.flag (apagado persistente via /daybreak-stop)
#   - primera ejecucion: copia config por defecto y crea logs/
#   - daemon vivo con la ruta actual -> no-op (evita duplicados)
#   - daemon vivo con ruta vieja (post-update de cache) -> lo mata y relanza
#   - daemon muerto -> lo lanza detached (mecanismo A; ver spike Task 1)
# SIEMPRE termina exit 0: jamas romper un SessionStart de Codex.
param(
    [string]$DataDir = $env:CLAUDE_PLUGIN_DATA,
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT,
    [string]$WatchScript = $(if ($PluginRoot) { Join-Path $PluginRoot 'scripts\watch.ps1' } else { $null })
)

function Initialize-PluginData {
    <# Crea $DataDir y $DataDir\logs; copia el config por defecto si el
       usuario aun no tiene el suyo. Devuelve la ruta del config del usuario. #>
    param([string]$DataDir, [string]$DefaultConfigSrc)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'logs'))
    $cfg = Join-Path $DataDir 'config.json'
    if (-not (Test-Path -LiteralPath $cfg) -and $DefaultConfigSrc -and (Test-Path -LiteralPath $DefaultConfigSrc)) {
        Copy-Item -LiteralPath $DefaultConfigSrc -Destination $cfg -Force
    }
    return $cfg
}

function Test-DaemonAlive {
    <# True solo si el PID existe, es pwsh y su CommandLine ejecuta watch.ps1
       (la ruta actual). Un pwsh vivo con otra ruta = daemon huérfano
       post-update -> false (el flujo principal lo reemplaza). #>
    param([int]$ProcId, [string]$WatchScriptPath)
    if ($ProcId -le 0) { return $false }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if ($null -eq $p -or $p.ProcessName -ne 'pwsh') { return $false }
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop).CommandLine
    } catch { return $false }
    if (-not $cmd) { return $false }
    $scriptPart = ($cmd -split ' -File ')[-1]
    return ($scriptPart.Trim('"').Trim("'").StartsWith($WatchScriptPath, [System.StringComparison]::OrdinalIgnoreCase))
}

function Invoke-EnsureDaemon {
    <# Flujo principal. Parametros inyectables para tests. #>
    param([string]$DataDir, [string]$PluginRoot, [string]$WatchScript)

    if (Test-Path -LiteralPath (Join-Path $DataDir 'disabled.flag')) { return }

    $defaultCfg = Join-Path $PluginRoot 'config.json'
    if ($PluginRoot -and (Split-Path $PluginRoot -Leaf) -eq 'tests') { $defaultCfg = Join-Path (Split-Path $PluginRoot) 'config.json' }
    $null = Initialize-PluginData $DataDir $defaultCfg

    $statePath = Join-Path $DataDir 'state.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content $statePath -Raw -Encoding utf8 | ConvertFrom-Json } catch { $state = $null }
    }

    if ($state -and (Test-DaemonAlive ([int]$state.pid) $WatchScript)) { return }

    if ($state -and $state.pid) {
        # vivo pero ya no ejecuta la ruta actual (update de cache) -> reemplazar
        $old = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
        if ($old) { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
    }

    $cfgPath = Join-Path $DataDir 'config.json'
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-File', $WatchScript, '-ConfigPath', $cfgPath
    ) -WindowStyle Hidden -WorkingDirectory $DataDir -PassThru

    [System.IO.File]::WriteAllText($statePath,
        (@{ pid = $proc.Id; script = $WatchScript; started = (Get-Date -Format o) } | ConvertTo-Json),
        [System.Text.UTF8Encoding]::new($false))
}

# --- main: solo cuando se invoca con -File (no al dot-sourcear en tests) -----
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($DataDir) { $null = Invoke-EnsureDaemon -DataDir $DataDir -PluginRoot $PluginRoot -WatchScript $WatchScript }
    } catch {
        # un hook jamas rompe el arranque de sesion
    }
    exit 0
}

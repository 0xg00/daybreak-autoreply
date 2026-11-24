# ensure-daemon.ps1 — hook SessionStart del plugin daybreak-autoreply.
# Garantiza un daemon watch.ps1 vivo con estado en PLUGIN_DATA:
#   - respeta disabled.flag (apagado persistente via /daybreak-stop)
#   - primera ejecucion: copia config por defecto y crea logs/
#   - daemon vivo con la ruta actual -> no-op (evita duplicados)
#   - daemon vivo con ruta vieja (post-update de cache) -> lo mata y relanza
#   - daemon muerto -> lo lanza detached (mecanismo A; ver spike Task 1)
#   - kill SIEMPRE con verificacion de identidad (pwsh + watch.ps1 en -File):
#     un PID reutilizado por Windows jamas recibe el Stop-Process
#   - mutex de archivo: dos SessionStart concurrentes no duplican daemon
# SIEMPRE termina exit 0: jamas romper un SessionStart de Codex.
param(
    [string]$DataDir = $env:CLAUDE_PLUGIN_DATA,
    [string]$PluginRoot = $env:CLAUDE_PLUGIN_ROOT,
    [string]$WatchScript = $(if ($PluginRoot) { Join-Path $PluginRoot 'scripts\watch.ps1' } else { $null }),
    [switch]$NoAutostartTask   # tests: no instalar/actualizar la tarea de inicio de sesion
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

function Test-IsWatchProcess {
    <# Identidad para kills: pwsh cuyo -File ejecuta watch.ps1 (cualquier
        instalacion/ruta). Evita matar procesos ajenos por reutilizacion de PID. #>
    param([System.Diagnostics.Process]$Proc)
    if ($null -eq $Proc -or $Proc.ProcessName -ne 'pwsh') { return $false }
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($Proc.Id)" -ErrorAction Stop).CommandLine
    } catch { return $false }
    if (-not $cmd -or $cmd -notmatch ' -File ') { return $false }
    $scriptPart = ($cmd -split ' -File ')[-1]
    return ($scriptPart.Trim('"').Trim("'") -match 'watch\.ps1')
}

function Invoke-EnsureDaemon {
    <# Flujo principal. Parametros inyectables para tests. #>
    param([string]$DataDir, [string]$PluginRoot, [string]$WatchScript)

    if (Test-Path -LiteralPath (Join-Path $DataDir 'disabled.flag')) { return }

    # mutex: serializa SessionStart concurrentes (dos ventanas a la vez)
    $lockPath = Join-Path $DataDir 'ensure.lock'
    $lock = $null
    for ($i = 0; $i -lt 10 -and -not $lock; $i++) {
        try { $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $lock) { return }   # otro ensure esta trabajando; el dejara daemon vivo
    try {
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
            # vivo pero ya no ejecuta la ruta actual (update de cache) -> reemplazar.
            # SOLO si sigue siendo un proceso watch (PID reutilizado = intocable).
            $old = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
            if ($old -and (Test-IsWatchProcess $old)) { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
        }

        $cfgPath = Join-Path $DataDir 'config.json'
        # ArgumentList NO entrecomilla: rutas con espacios hay que quotearlas a mano
        # (spike/review: sin comillas el hijo muere exit 64 en perfiles con espacios)
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-File', ('"{0}"' -f $WatchScript), '-ConfigPath', ('"{0}"' -f $cfgPath)
        ) -WindowStyle Hidden -WorkingDirectory $DataDir -PassThru

        [System.IO.File]::WriteAllText($statePath,
            (@{ pid = $proc.Id; script = $WatchScript; started = (Get-Date -Format o) } | ConvertTo-Json),
            [System.Text.UTF8Encoding]::new($false))

        # --- autostart a prueba de reboots -------------------------------------
        # La tarea de inicio de sesion apunta a un launcher ESTABLE en PLUGIN_DATA
        # (la cache del plugin cambia de version en cada update); este launcher se
        # re-escribe en cada ensure con las rutas actuales -> se auto-repara solo.
        try {
            $launcher = Join-Path $DataDir 'autostart.ps1'
            $launcherContent = @"
`$env:CLAUDE_PLUGIN_ROOT = '$PluginRoot'
`$env:CLAUDE_PLUGIN_DATA = '$DataDir'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '$PluginRoot\scripts\ensure-daemon.ps1'
"@
            [System.IO.File]::WriteAllText($launcher, $launcherContent, [System.Text.UTF8Encoding]::new($false))
            if (-not $NoAutostartTask -and $DataDir -notmatch 'Temp\\') {
                # rutas sin espacios (PROGRA~1 + plugin-data) -> sin infierno de comillas
                $tr = "C:\PROGRA~1\POWERS~1\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $launcher"
                [void](schtasks /create /f /tn 'DaybreakAutoreply' /tr $tr /sc onlogon 2>&1)
            }
        } catch { }
    }
    finally {
        if ($lock) { $lock.Dispose() }
    }
}

# --- main: solo cuando se invoca con -File (no al dot-sourcear en tests) -----
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # observabilidad: una linea por ejecucion responde "disparo el hook?" para siempre
        if ($DataDir) {
            try {
                [void](New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'logs'))
                Add-Content -LiteralPath (Join-Path $DataDir 'logs\ensure.log') -Value ("{0} ensure invocado (plugin_root={1})" -f (Get-Date -Format o), $PluginRoot) -Encoding utf8
            } catch { }
            $null = Invoke-EnsureDaemon -DataDir $DataDir -PluginRoot $PluginRoot -WatchScript $WatchScript
        }
    } catch {
        # un hook jamas rompe el arranque de sesion
    }
    exit 0
}

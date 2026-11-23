# Daybreak Watchdog - nucleo de deteccion (Task 1)
# Vigila los rollouts de Codex CLI (~/.codex/sessions/**/rollout-*.jsonl, JSONL
# append en vivo) y detecta turnos muertos por errores estructurales
# (payload.error.codex_error_info en watch_codes).
# Uso: pwsh -File watch.ps1 [-ConfigPath config.json] [-NoDaemon]

param(
    [string]$ConfigPath = "config.json",
    [switch]$NoDaemon
)

# Solapa 256 chars: cola final que se pre-pende a la siguiente lectura para
# no perder un JSON partido entre dos polls.
$script:OverlapChars = 256
# Safety valve: si una linea nunca cierra (>64KB sin \n), recorta el tail al solape.
$script:MaxTailChars = 65536

# --- Config ------------------------------------------------------------------

function Load-Config {
    <# Hashtable con defaults; el archivo JSON (si existe) sobreescribe claves. #>
    param([string]$Path)

    $cfg = @{
        sessions_dir                = (Join-Path $env:USERPROFILE '.codex\sessions')
        log_file                    = 'watchdog.log'
        send_text                   = '/goal resume'
        responses                   = @{
            'cyber_policy'            = '/goal resume'
            'usage_limit_exceeded'    = '/goal resume'
            'context_window_exceeded' = '/compact'
        }
        watch_codes                 = @('cyber_policy', 'usage_limit_exceeded', 'context_window_exceeded')
        pattern                     = '"codex_error_info":"cyber_policy'
        delay_s                     = 3
        cooldown_s                  = 60
        max_burst                   = 3
        burst_window_min            = 10
        pause_after_limit_min       = 15
        require_terminal_foreground = $true
        terminals                   = @('WindowsTerminal', 'conhost', 'cmd', 'powershell', 'pwsh', 'Code', 'alacritty', 'wezterm-gui', 'mintty')
        dry_run                     = $true
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                $cfg[$prop.Name] = $prop.Value
            }
        }
        catch {
            Write-Warning "config invalido ('$Path'): $($_.Exception.Message) - usando defaults"
        }
    }

    # responses debe ser hashtable para indexar $cfg.responses[$codigo]
    if ($cfg['responses'] -isnot [hashtable]) {
        $resp = @{}
        foreach ($p in $cfg['responses'].PSObject.Properties) {
            $resp[[string]$p.Name] = [string]$p.Value
        }
        $cfg['responses'] = $resp
    }

    return $cfg
}

# --- Lectura incremental -------------------------------------------------------

function Get-NewContent {
    <# Lee desde el offset guardado (UTF-8, FileStream FileShare ReadWrite|Delete).
       Si el archivo encogio (rotacion), relee desde 0 y resetea el offset.
       Offsets por archivo en $Offsets. Devuelve Content y Offset final. #>
    param([string]$Path, [hashtable]$Offsets)

    if ($null -eq $Offsets) { $Offsets = @{} }
    $offset = if ($Offsets.ContainsKey($Path)) { [long]$Offsets[$Path] } else { [long]0 }
    $content = ''

    $fi = [System.IO.FileInfo]::new($Path)
    if (-not $fi.Exists) {
        return [pscustomobject]@{ Content = $content; Offset = $offset }
    }

    $size = $fi.Length
    if ($size -lt $offset) { $offset = [long]0 }  # rotacion: releer desde 0

    if ($size -gt $offset) {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
            $len = [int]($size - $offset)
            $buf = [byte[]]::new($len)
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            if ($read -gt 0) {
                $content = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                $offset += $read
            }
        }
        finally { $fs.Dispose() }
    }

    $Offsets[$Path] = $offset
    return [pscustomobject]@{ Content = $content; Offset = $offset }
}

# --- Match ---------------------------------------------------------------------

function Find-BlockEvent {
    <# Codigo codex_error_info vigilado encontrado en $Text, o $null.
       Por linea: solo si contiene "type":"event_msg" hace ConvertFrom-Json y
       devuelve payload.error.codex_error_info si existe y esta en $WatchCodes.
       Exigir el campo real (no substring) evita el falso positivo de la cadena
       citada dentro de un input_text de usuario. #>
    param(
        [string]$Text,
        [string[]]$WatchCodes = @('cyber_policy', 'usage_limit_exceeded', 'context_window_exceeded')
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }

    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.Contains('"type":"event_msg"')) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $info = $obj.payload.error.codex_error_info
        if ($info -and $WatchCodes -contains [string]$info) { return [string]$info }
    }
    return $null
}

# --- Control de rafaga ----------------------------------------------------------

function Test-BurstAllowed {
    <# Cooldown + ventana de rafaga + pausa tras limite, segun $History de disparos.
       Devuelve Allowed y la History (sin mutarla). #>
    param(
        [datetime]$Now,
        [System.Collections.Generic.List[datetime]]$History,
        [hashtable]$Cfg
    )

    $cooldownS = [double]$Cfg['cooldown_s']
    $maxBurst  = [int]$Cfg['max_burst']
    $windowMin = [double]$Cfg['burst_window_min']
    $pauseMin  = [double]$Cfg['pause_after_limit_min']

    if ($null -eq $History) { $History = [System.Collections.Generic.List[datetime]]::new() }

    $allowed = $true

    if ($History.Count -gt 0) {
        # cooldown: el ultimo disparo es demasiado reciente
        if (($Now - $History[$History.Count - 1]).TotalSeconds -lt $cooldownS) { $allowed = $false }

        # ventana de rafaga: demasiados disparos dentro de la ventana
        $inWindow = 0
        foreach ($t in $History) {
            if (($Now - $t).TotalMinutes -lt $windowMin) { $inWindow++ }
        }
        if ($inWindow -ge $maxBurst) { $allowed = $false }

        # pausa tras limite: la rafaga llego a max_burst y la pausa aun no expira
        for ($i = $maxBurst - 1; $i -lt $History.Count; $i++) {
            $spanMin = ($History[$i] - $History[$i - $maxBurst + 1]).TotalMinutes
            if ($spanMin -lt $windowMin -and ($Now - $History[$i]).TotalMinutes -lt $pauseMin) {
                $allowed = $false
            }
        }
    }

    return [pscustomobject]@{ Allowed = [bool]$allowed; History = $History }
}

# --- Log ------------------------------------------------------------------------

function Write-Log {
    <# Append a log_file con timestamp ISO 8601. #>
    param([string]$Msg, [hashtable]$Cfg)

    $logFile = 'watchdog.log'
    if ($Cfg -and $Cfg['log_file']) { $logFile = [string]$Cfg['log_file'] }
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Msg
    [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

# --- Autorespuesta (stub; Task 2 lo reemplaza por la inyeccion real) --------------

function Invoke-Autorespond {
    <# Stub Task 1: solo loguea. Firma (texto, codigo, cfg) para Task 2. #>
    param([string]$Text, [string]$Code, [hashtable]$Cfg)

    Write-Log ("AUTORESPOND code={0} texto={1} dry_run={2} (stub Task 1)" -f $Code, $Text, [bool]$Cfg['dry_run']) $Cfg
}

# --- Loop daemon (solo si no -NoDaemon) ---------------------------------------------

if (-not $NoDaemon) {
    $cfg      = Load-Config $ConfigPath
    $offsets  = @{}
    $buffers  = @{}
    $history  = [System.Collections.Generic.List[datetime]]::new()
    $lastScan = Get-Date  # solo archivos tocados desde el arranque (no replay de historia vieja)

    Write-Log ("daemon iniciado sessions_dir={0} watch_codes={1}" -f $cfg['sessions_dir'], ($cfg['watch_codes'] -join ',')) $cfg

    while ($true) {
        $files = @(Get-ChildItem -LiteralPath $cfg['sessions_dir'] -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $lastScan })

        foreach ($file in $files) {
            try {
                $chunk = Get-NewContent $file.FullName $offsets
                if ([string]::IsNullOrEmpty($chunk.Content)) { continue }

                if (-not $buffers.ContainsKey($file.FullName)) { $buffers[$file.FullName] = '' }
                $buffers[$file.FullName] += $chunk.Content

                $buf = [string]$buffers[$file.FullName]
                $lastNl = $buf.LastIndexOf("`n")
                if ($lastNl -ge 0) {
                    $complete = $buf.Substring(0, $lastNl + 1)
                    foreach ($line in ($complete -split "`r?`n")) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        $code = Find-BlockEvent $line $cfg['watch_codes']
                        if (-not $code) { continue }

                        $decision = Test-BurstAllowed (Get-Date) $history $cfg
                        $history = $decision.History
                        if ($decision.Allowed) {
                            $history.Add((Get-Date))
                            $texto = $cfg['responses'][$code] ?? [string]$cfg['send_text']
                            Write-Log ("MATCH code={0} file={1} -> autorespond" -f $code, $file.Name) $cfg
                            Invoke-Autorespond $texto $code $cfg
                        }
                        else {
                            Write-Log ("MATCH code={0} file={1} -> suprimido (cooldown/rafaga)" -f $code, $file.Name) $cfg
                        }
                    }
                    # el tail incompleto queda para el proximo poll (solapa)
                    $buffers[$file.FullName] = $buf.Substring($lastNl + 1)
                }

                $tail = [string]$buffers[$file.FullName]
                if ($tail.Length -gt $script:MaxTailChars) {
                    $buffers[$file.FullName] = $tail.Substring($tail.Length - $script:OverlapChars)
                }
            }
            catch {
                Write-Log ("ERROR procesando {0}: {1}" -f $file.FullName, $_.Exception.Message) $cfg
            }
        }

        $lastScan = Get-Date
        Start-Sleep -Seconds 1
    }
}

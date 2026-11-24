# Daybreak Watchdog - nucleo de deteccion (Task 1) + inyeccion foreground-safe (Task 2)
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
# Terminales validos por defecto (compartido por Load-Config y Get-CodexParentTerminal).
$script:DefaultTerminals = @('WindowsTerminal', 'conhost', 'cmd', 'powershell', 'pwsh', 'Code', 'alacritty', 'wezterm-gui', 'mintty')

# --- Config ------------------------------------------------------------------

function Load-Config {
    <# Hashtable con defaults; el archivo JSON (si existe) sobreescribe claves. #>
    param([string]$Path)

    $cfg = @{
        sessions_dir                = (Join-Path $env:USERPROFILE '.codex\sessions')
        log_file                    = 'watchdog.log'
        send_text                   = 'continua'
        responses                   = @{
            'cyber_policy'            = 'continua'
            'usage_limit_exceeded'    = 'continua'
            'context_window_exceeded' = '/compact'
        }
        watch_codes                 = @('cyber_policy', 'usage_limit_exceeded', 'context_window_exceeded')
        pattern                     = '"codex_error_info":"cyber_policy'
        delivery                    = 'queue'
        sendkeys_fallback           = $false
        per_thread_max              = 3
        per_thread_window_min       = 5
        per_thread_pause_min        = 15
        delay_s                     = 3
        cooldown_s                  = 0
        max_burst                   = 0
        burst_window_min            = 10
        pause_after_limit_min       = 15
        require_terminal_foreground = $true
        foreground_wait_s           = 120
        terminals                   = $script:DefaultTerminals
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

    # claves desconocidas: un typo (dryrun, delai_s) NO puede caer en silencio
    # a defaults — se recogen para que el daemon las loguee como WARNING
    $known = @('sessions_dir','log_file','send_text','responses','watch_codes','pattern',
        'delivery','sendkeys_fallback','per_thread_max','per_thread_window_min','per_thread_pause_min',
        'delay_s','cooldown_s','max_burst','burst_window_min','pause_after_limit_min',
        'require_terminal_foreground','foreground_wait_s','terminals','dry_run','codex_exe')
    if ($json) {
        $unknown = @($json.PSObject.Properties | Where-Object { $known -notcontains $_.Name } | ForEach-Object { $_.Name })
        if ($unknown.Count -gt 0) {
            Write-Warning ("config '$Path': claves desconocidas (se ignoran): $($unknown -join ', ')")
            $cfg['__unknown_keys'] = $unknown
        }
    }

    # log_file relativo -> junto al config (PLUGIN_DATA), no al CWD del daemon
    if ($cfg['log_file'] -and $cfg['log_file'] -notmatch '^[A-Za-z]:[\\/]' -and $cfg['log_file'] -notmatch '^\\\\') {
        $cfg['log_file'] = Join-Path (Split-Path -Parent $Path) $cfg['log_file']
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
       Por linea: solo si casa "type"\s*:\s*"event_msg" (con o sin espacios
       alrededor de los dos puntos) hace ConvertFrom-Json y devuelve
       payload.error.codex_error_info si existe y esta en $WatchCodes.
       Exigir el campo real (no substring) evita el falso positivo de la cadena
       citada dentro de un input_text de usuario. #>
    param(
        [string]$Text,
        [string[]]$WatchCodes = @('cyber_policy', 'usage_limit_exceeded', 'context_window_exceeded')
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '"type"\s*:\s*"event_msg"') { continue }
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
        # cooldown: el ultimo disparo es demasiado reciente (0 = sin cooldown;
        # los bloques dentro de la ventana de delay se envian igual)
        if ($cooldownS -gt 0 -and ($Now - $History[$History.Count - 1]).TotalSeconds -lt $cooldownS) { $allowed = $false }

        # ventana de rafaga: demasiados disparos dentro de la ventana (0 = sin limite)
        if ($maxBurst -gt 0) {
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
    }

    return [pscustomobject]@{ Allowed = [bool]$allowed; History = $History }
}

# --- Log ------------------------------------------------------------------------

function Write-Log {
    <# Append a log_file con timestamp ISO 8601. Blindado (I1): si la escritura
       falla (log bloqueado por antivirus/backup, ruta invalida), la excepcion
       NO escapa ni mata al daemon — cae a Write-Warning. #>
    param([string]$Msg, [hashtable]$Cfg)

    $logFile = 'watchdog.log'
    if ($Cfg -and $Cfg['log_file']) { $logFile = [string]$Cfg['log_file'] }
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Msg
    try {
        [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        try { Write-Warning ("log inaccesible '{0}': {1}" -f $logFile, $_.Exception.Message) } catch { }
    }
}

# --- Inyeccion (Task 2): foreground, ventana, clipboard, SendKeys, toast ----------

# P/Invoke minimo para la ventana en primer plano. El guard evita recompilar
# el tipo si el script se dot-sourcea dos veces en la misma sesion.
if (-not ('DaybreakWin32' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DaybreakWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@
}

function Get-ForegroundProcessName {
    <# Nombre (sin extension) del proceso dueno de la ventana en primer plano, o ''. #>
    try {
        $hwnd = [DaybreakWin32]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return '' }
        $procId = [uint32]0
        [void][DaybreakWin32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        if ($procId -le 0) { return '' }
        $p = Get-Process -Id $procId -ErrorAction Stop
        return [System.IO.Path]::GetFileNameWithoutExtension($p.ProcessName)
    }
    catch { return '' }
}

function Test-IsTerminalProcess {
    <# True si $ProcName (se ignora extension; case-insensitive) esta en $Terminals. #>
    param([string]$ProcName, [string[]]$Terminals)

    if ([string]::IsNullOrWhiteSpace($ProcName) -or $null -eq $Terminals -or $Terminals.Count -eq 0) { return $false }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ProcName.Trim())
    foreach ($t in $Terminals) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($name -eq [System.IO.Path]::GetFileNameWithoutExtension($t.Trim())) { return $true }
    }
    return $false
}

function Get-CodexParentTerminal {
    <# HWND del primer ancestro-terminal de un proceso codex (nombre codex* o
       node con 'codex' en su linea de comando), o [IntPtr]::Zero si no hay. #>
    param([string[]]$Terminals = $script:DefaultTerminals)

    $zero = [IntPtr]::Zero
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop
    }
    catch { return $zero }

    $byId = @{}
    foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }

    $candidates = @($procs | Where-Object {
        $n = [string]$_.Name
        ($n -like 'codex*') -or (($n -like 'node*') -and ([string]$_.CommandLine -match 'codex'))
    })

    foreach ($cand in $candidates) {
        $visited = @{}   # guard contra ciclos de ParentProcessId
        $cur = $cand
        while ($cur) {
            $ppid = [int]$cur.ParentProcessId
            if ($ppid -le 0 -or $visited.ContainsKey($ppid)) { break }
            $visited[$ppid] = $true
            $parent = $byId[$ppid]
            if ($null -eq $parent) { break }
            if (Test-IsTerminalProcess ([string]$parent.Name) $Terminals) {
                try {
                    $gp = Get-Process -Id $ppid -ErrorAction Stop
                    if ($gp.MainWindowHandle -ne $zero) { return $gp.MainWindowHandle }
                }
                catch { }  # sin ventana/acceso: seguir subiendo
            }
            $cur = $parent
        }
    }
    return $zero
}

function Send-Toast {
    <# Toast best-effort via WinRT; cualquier fallo se ignora (el log ya registra el disparo). #>
    param([string]$Title, [string]$Body)

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        [void]$texts.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$texts.Item(1).AppendChild($xml.CreateTextNode($Body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Daybreak Watchdog').Show($toast)
    }
    catch { }
}

function Invoke-Autorespond {
    <# Inyeccion foreground-safe de la respuesta en el terminal del codex.
       Orden: delay_s -> asegurar terminal en foreground (Get-CodexParentTerminal +
       SetForegroundWindow + polling hasta foreground_wait_s) -> si dry_run solo
       log DRYRUN; si no: clipboard backup -> Set-Clipboard -> ^v -> {ENTER} ->
       restaurar clipboard -> toast best-effort + log.
       Devuelve el estado del intento (I2): 'SENT' (enviado), 'DRYRUN' (simulado),
       'ABORT' (sin terminal en foreground tras la espera) o 'ERROR' (fallo de
       clipboard/SendKeys). El toast y la linea AUTORESPOND solo aparecen en SENT;
       un fallo real se registra como AUTORESPOND_FAILED. El llamador decide que
       estados consumen cooldown/rafaga.
       $ForegroundProcName: override de testabilidad (T7b); vacio = foreground real. #>
    param(
        [string]$Text,
        [string]$Code,
        [hashtable]$Cfg,
        [string]$ForegroundProcName = ''
    )

    # 1) delay inicial
    $delayS = 3.0
    if ($null -ne $Cfg['delay_s']) { $delayS = [double]$Cfg['delay_s'] }
    if ($delayS -gt 0) { Start-Sleep -Seconds $delayS }

    $terms = @()
    if ($Cfg['terminals']) { $terms = @([string[]]$Cfg['terminals']) }

    # 2) foreground: override de test o ventana real en primer plano
    $fgName = if (-not [string]::IsNullOrEmpty($ForegroundProcName)) { $ForegroundProcName } else { Get-ForegroundProcessName }

    $requireFg = [bool]$Cfg['require_terminal_foreground']
    if ($requireFg -and -not (Test-IsTerminalProcess $fgName $terms)) {
        # 3) intento de foco sobre el terminal padre del codex. Solo en modo real:
        #    con override de test el foreground esta fijado y no se toca ninguna ventana.
        if ([string]::IsNullOrEmpty($ForegroundProcName)) {
            try {
                $hwnd = Get-CodexParentTerminal $terms
                if ($hwnd -ne [IntPtr]::Zero -and [DaybreakWin32]::SetForegroundWindow($hwnd)) {
                    Start-Sleep -Milliseconds 250
                    $fgName = Get-ForegroundProcessName
                }
            }
            catch { }
        }

        # 4) polling del foreground hasta foreground_wait_s (por defecto 120)
        $waitS = 120.0
        if ($null -ne $Cfg['foreground_wait_s']) { $waitS = [double]$Cfg['foreground_wait_s'] }
        $deadline = (Get-Date).AddSeconds($waitS)
        while (-not (Test-IsTerminalProcess $fgName $terms) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $fgName = Get-ForegroundProcessName
        }

        if (-not (Test-IsTerminalProcess $fgName $terms)) {
            Write-Log ("AUTORESPOND ABORT code={0} foreground={1} no es terminal tras {2}s" -f $Code, $fgName, $waitS) $Cfg
            return 'ABORT'
        }
    }

    # 5) dry_run: nunca toca clipboard ni teclas
    if ([bool]$Cfg['dry_run']) {
        Write-Log ("DRYRUN code={0} texto={1} foreground={2}" -f $Code, $Text, $fgName) $Cfg
        return 'DRYRUN'
    }

    # 6) clipboard backup (restaurar solo si habia contenido no vacio)
    $prevClip = ''
    $hadClip = $false
    try {
        $prev = Get-Clipboard -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrEmpty($prev)) { $prevClip = [string]$prev; $hadClip = $true }
    }
    catch {
        Write-Log ("ERROR clipboard backup: {0}" -f $_.Exception.Message) $Cfg
    }

    # 7) pegar el texto y confirmar con Enter
    $enviado = $false
    try {
        Set-Clipboard -Value $Text -ErrorAction Stop
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.SendKeys('^v')
        Start-Sleep -Milliseconds 300
        [void]$shell.SendKeys('{ENTER}')
        $enviado = $true
    }
    catch {
        Write-Log ("ERROR inyeccion SendKeys: {0}" -f $_.Exception.Message) $Cfg
    }

    if ($hadClip) {
        try { Set-Clipboard -Value $prevClip -ErrorAction Stop }
        catch { Write-Log ("ERROR restaurando clipboard: {0}" -f $_.Exception.Message) $Cfg }
    }

    # 8) toast y linea AUTORESPOND SOLO si el envio salio (senal de exito, I2):
    #    un fallo de clipboard/SendKeys se registra como AUTORESPOND_FAILED para
    #    que el usuario no confie en una inyeccion que nunca ocurrio.
    if ($enviado) {
        Send-Toast 'Daybreak Watchdog' ("autorespond {0}" -f $Code)
        Write-Log ("AUTORESPOND code={0} texto={1} foreground={2}" -f $Code, $Text, $fgName) $Cfg
        return 'SENT'
    }
    Write-Log ("AUTORESPOND_FAILED code={0} texto={1} foreground={2}" -f $Code, $Text, $fgName) $Cfg
    return 'ERROR'
}

# --- Entrega por codex queue (Adenda v0.2) -----------------------------------------

function Get-RolloutThreadIds {
    <# Extrae TODOS los UUID del nombre de un rollout, en orden de aparicion.
        rollout-<ts>-<session-uuid>_<thread-uuid>.jsonl -> 2 ids
        rollout-<ts>-<uuid>.jsonl                       -> 1 id
        El primero que acepte `codex queue` gana (los de subagentes
        descargados fallan con -32600 y se saltan). #>
    param([string]$FileName)
    $ms = [regex]::Matches($FileName, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    return @($ms | ForEach-Object { $_.Value })   # envolver con @() en el caller si importa el cardenal
}

function Invoke-QueueDelivery {
    <# Entrega el texto en LA sesión bloqueada vía `codex queue --thread`.
        Sin teclado, foco ni ventanas: funciona con el usuario en cualquier
        app y el codex en cualquier pestaña. Devuelve SENT | ERROR. #>
    param(
        [string]$Text,
        [string]$Code,
        [string[]]$ThreadIds,
        [hashtable]$Cfg
    )
    $codexExe = if ($Cfg['codex_exe']) { [string]$Cfg['codex_exe'] } else { 'codex' }
    foreach ($id in @($ThreadIds)) {
        if (-not $id) { continue }
        try {
            # SIN --resume: el intento de resume roba el foco de pestana en el TUI
            $out = & $codexExe queue --thread $id --message $Text 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log ("QUEUE_SENT code={0} thread={1} texto={2} salida={3}" -f $Code, $id, $Text, (($out | Out-String).Trim() -replace "`r?`n", ' | ')) $Cfg
                return 'SENT'
            }
            Write-Log ("QUEUE_RETRY thread={0} exit={1} salida={2}" -f $id, $LASTEXITCODE, (($out | Out-String).Trim() -replace "`r?`n", ' | ')) $Cfg
        }
        catch {
            Write-Log ("QUEUE_RETRY thread={0} excepcion={1}" -f $id, $_.Exception.Message) $Cfg
        }
    }
    Write-Log ("QUEUE_FAILED code={0} texto={1} (ningun UUID acepto el encolado)" -f $Code, $Text) $Cfg
    return 'ERROR'
}

function Test-ThreadAllowed {
    <# Breaker por hilo: distinto del ritmo global. Un MISMO thread que acumula
        per_thread_max respuestas dentro de per_thread_window_min entra en pausa
        per_thread_pause_min (bucle bloqueo->continua->bloqueo sin salida).
        per_thread_max = 0 -> desactivado (todo se envia). #>
    param(
        [datetime]$Now,
        [System.Collections.Generic.List[datetime]]$History,
        [hashtable]$Cfg
    )
    $maxSends = [int]$Cfg['per_thread_max']
    $windowMin = [double]$Cfg['per_thread_window_min']
    $pauseMin = [double]$Cfg['per_thread_pause_min']

    if ($null -eq $History) { $History = [System.Collections.Generic.List[datetime]]::new() }

    $allowed = $true
    if ($maxSends -gt 0 -and $History.Count -ge $maxSends) {
        $inWindow = 0
        foreach ($t in $History) {
            if (($Now - $t).TotalMinutes -lt $windowMin) { $inWindow++ }
        }
        if ($inWindow -ge $maxSends) {
            $last = $History[$History.Count - 1]
            if (($Now - $last).TotalMinutes -lt $pauseMin) { $allowed = $false }
        }
    }
    return [pscustomobject]@{ Allowed = [bool]$allowed; History = $History }
}

# --- Loop daemon (solo si no -NoDaemon) ---------------------------------------------

if (-not $NoDaemon) {
    $cfg      = Load-Config $ConfigPath
    $offsets  = @{}
    $buffers  = @{}
    $history  = [System.Collections.Generic.List[datetime]]::new()
    $threadHist = @{}   # breaker por hilo: uuid -> List[datetime] de envios
    $lastScan = Get-Date  # solo archivos tocados desde el arranque (no replay de historia vieja)

    # C1: todo rollout YA existente al arrancar se inicializa con offset = su
    # tamano actual ($buffers queda vacio para esas rutas). Sin esto, el primer
    # append sobre un rollout preexistente se leia ENTERO desde byte 0 y cada
    # evento vigilado de su historia se convertia en MATCH (pulsaciones reales
    # por errores de hace dias). Solo los archivos creados despues del arranque
    # se leen desde 0.
    if (Test-Path -LiteralPath $cfg['sessions_dir']) {
        Get-ChildItem -LiteralPath $cfg['sessions_dir'] -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
            ForEach-Object { $offsets[[string]$_.FullName] = $_.Length }
    }
    else {
        # M1: sessions_dir mal escrito = daemon zombie silencioso; dejar rastro una sola vez.
        Write-Log ("WARNING sessions_dir no existe, no se vigila nada: {0}" -f $cfg['sessions_dir']) $cfg
        Write-Warning ("sessions_dir no existe, no se vigila nada: {0}" -f $cfg['sessions_dir'])
    }

    Write-Log ("daemon iniciado sessions_dir={0} watch_codes={1}" -f $cfg['sessions_dir'], ($cfg['watch_codes'] -join ',')) $cfg
    if ($cfg['__unknown_keys']) {
        Write-Log ("WARNING config: claves desconocidas ignoradas: {0}" -f ($cfg['__unknown_keys'] -join ', ')) $cfg
    }
    if (-not (Test-Path -LiteralPath $cfg['sessions_dir'])) {
        Write-Log ("WARNING sessions_dir no existe: {0} — el daemon vigila nada hasta que exista" -f $cfg['sessions_dir']) $cfg
    }

    while ($true) {
        # capturar el instante de escaneo ANTES de enumerar: los appends entre el
        # snapshot y la actualizacion de lastScan quedan cubiertos en el proximo poll
        # (los offsets hacen inofensiva la re-enumeracion)
        $scanStart = Get-Date
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
                            $texto = $cfg['responses'][$code] ?? [string]$cfg['send_text']
                            Write-Log ("MATCH code={0} file={1} -> autorespond" -f $code, $file.Name) $cfg
                            if ($cfg['delivery'] -eq 'queue') {
                                $ids = Get-RolloutThreadIds $file.Name
                                # breaker por hilo: un mismo thread en bucle estrecho
                                # (bloqueo->continua->bloqueo) se pausa, no se spamea
                                $tKey = if (@($ids).Count -gt 0) { @($ids)[0] } else { $file.Name }
                                if (-not $threadHist.ContainsKey($tKey)) { $threadHist[$tKey] = [System.Collections.Generic.List[datetime]]::new() }
                                $tdec = Test-ThreadAllowed (Get-Date) $threadHist[$tKey] $cfg
                                $threadHist[$tKey] = $tdec.History
                                if (-not $tdec.Allowed) {
                                    Write-Log ("MATCH code={0} file={1} -> pausa por bucle del hilo {2}" -f $code, $file.Name, $tKey) $cfg
                                    continue
                                }
                                $estado = Invoke-QueueDelivery $texto $code $ids $cfg
                                if ($estado -eq 'SENT') { $threadHist[$tKey].Add((Get-Date)) }
                                if ($estado -eq 'ERROR') {
                                    if ($cfg['sendkeys_fallback']) {
                                        Write-Log 'QUEUE agotado -> fallback sendkeys (habilitado en config)' $cfg
                                        $estado = Invoke-Autorespond $texto $code $cfg
                                    }
                                    else {
                                        # sin fallback: NUNCA teclas a ventanas ajenas a la sesion
                                        Write-Log 'QUEUE agotado -> sin fallback sendkeys (sendkeys_fallback=false)' $cfg
                                    }
                                }
                            }
                            else {
                                $estado = Invoke-Autorespond $texto $code $cfg
                            }
                            # I2: cooldown/rafaga solo consumen los estados que
                            # representan un intento real de envio (SENT/DRYRUN/
                            # ERROR; DRYRUN y ERROR cuentan a proposito). ABORT
                            # no consumio nada: no ocupa sitio en la historia.
                            if ($estado -ne 'ABORT') { $history.Add((Get-Date)) }
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

        $lastScan = $scanStart
        Start-Sleep -Seconds 1
    }
}

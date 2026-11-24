# Test E2E dry-run — Daybreak Watchdog (Task 3)
# Run: pwsh -File tests/e2e-dryrun.ps1
#
# Ciclo completo contra el daemon REAL (pwsh -File watch.ps1), pero con un
# sessions_dir TEMPORAL aislado (NUNCA ~/.codex/sessions: en esta maquina hay
# sesiones reales activas; si dry_run fallara al gatear, un test apuntado alli
# enviaria teclas de verdad). Con dry_run=true el daemon solo puede loguear.
#
# Flujo: rollout fake vacio + rollout PRE-LLENADO con el evento ANTES del
# arranque (regresion C1: su historia no debe disparar nada) -> config temporal
# (dry_run, delay 0, sin foreground) -> arrancar daemon como proceso -> esperar
# 2 s -> inyectar la linea event_msg del spec (dos copias en un solo append: la
# 2a debe caer por cooldown) y appendear una linea inofensiva al pre-llenado ->
# esperar 3 s -> matar por PID y confirmar muerte -> asserts del log:
# MATCH + DRYRUN exactamente una vez + suprimido por cooldown + sin AUTORESPOND
# + el rollout pre-llenado sin ningun MATCH/DRYRUN por su historia (offsets al
# arranque).

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

$root     = Join-Path $env:TEMP 'daybreak-e2e'
$sessions = Join-Path $root 'sessions\2026\11\23'
$rollout  = Join-Path $sessions 'rollout-test.jsonl'
$log      = Join-Path $root 'e2e-watchdog.log'
$cfgPath  = Join-Path $root 'config.json'
$stdout   = Join-Path $root 'daemon-stdout.txt'
$stderr   = Join-Path $root 'daemon-stderr.txt'

# Linea event_msg del spec (una linea JSONL): payload.error.codex_error_info = cyber_policy
$eventLine = '{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Daybreak","codex_error_info":"cyber_policy"}}}'

$proc = $null

try {
    # 0) restos de corridas previas: solo procesos cuyo CommandLine apunta a
    #    ESTE dir temporal (jamas por nombre solo), para que el test sea hermetico
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { ([string]$_.CommandLine) -match [regex]::Escape($root) } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }

    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $sessions -Force)
    # rollout vacio, como una sesion recien abierta
    [System.IO.File]::WriteAllText($rollout, '', [System.Text.UTF8Encoding]::new($false))

    # C1: rollout PRE-LLENADO con el evento ANTES de arrancar el daemon, como
    # una sesion vieja que codex todavia appendea: su historia no debe disparar.
    $rolloutHistorico = Join-Path $sessions 'rollout-historic.jsonl'
    [System.IO.File]::WriteAllText($rolloutHistorico, $eventLine + "`n", [System.Text.UTF8Encoding]::new($false))

    # config temporal aislada: dry_run=true => nada de clipboard ni teclas
    $cfg = [ordered]@{
        sessions_dir                = $sessions
        log_file                    = $log
        dry_run                     = $true
        delivery                    = 'sendkeys'   # suite del motor legacy
        delay_s                     = 0
        require_terminal_foreground = $false
        foreground_wait_s           = 1
        cooldown_s                  = 60
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

    # 1) arrancar el daemon como proceso independiente, salida redirigida
    $watch = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\watch.ps1')).Path
    $daemonArgs = '-NoProfile -NoLogo -File "{0}" -ConfigPath "{1}"' -f $watch, $cfgPath
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $daemonArgs -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Assert ($null -ne $proc -and $proc.Id -gt 0) "daemon arrancado como proceso (PID $($proc.Id))"

    # 2) espera 2 s: el daemon debe seguir vivo (config valida, loop andando)
    Start-Sleep -Seconds 2
    Assert (-not $proc.HasExited) 'daemon sigue vivo tras 2s (no crashea con la config temporal)'

    # 3) inyectar la linea del spec DOS veces en un solo Add-Content: la 1a dispara,
    #    la 2a debe caer por cooldown -> DRYRUN una sola vez si el dedup funciona
    Add-Content -LiteralPath $rollout -Value @($eventLine, $eventLine) -Encoding utf8

    # 3b) C1: append inofensivo (sin codigo vigilado) sobre el rollout pre-llenado.
    #     El daemon solo debe leer este delta (su offset quedo fijado al arranque),
    #     NUNCA la historia preexistente: sin MATCH ni DRYRUN por rollout-historic.
    $latido = '{"type":"event_msg","payload":{"type":"user_message","content":[{"type":"input_text","text":"latido inofensivo"}]}}'
    Add-Content -LiteralPath $rolloutHistorico -Value $latido -Encoding utf8

    # 4) espera 3 s (poll del daemon: 1 s; sobra para procesar)
    Start-Sleep -Seconds 3

    # 5) matar por PID y confirmar la muerte (Wait + HasExited)
    try {
        if (-not $proc.HasExited) { $proc.Kill() }
        [void]$proc.WaitForExit(5000)
    }
    catch { }
    Assert ($proc.HasExited) 'daemon muerto tras Kill (WaitForExit + HasExited)'

    # 6) asserts sobre el log del daemon
    Assert (Test-Path -LiteralPath $log) 'log del daemon existe (crecio durante la corrida)'
    $logText = Get-Content -LiteralPath $log -Raw
    Assert ($logText -match [regex]::Escape("daemon iniciado sessions_dir=$sessions")) 'daemon vigila SOLO el sessions_dir temporal aislado'
    Assert ($logText -match 'MATCH code=cyber_policy') 'evento cyber_policy detectado (MATCH en log)'
    $dryrun = ([regex]::Matches($logText, 'DRYRUN')).Count
    Assert ($dryrun -eq 1) "DRYRUN aparece exactamente una vez (dedup por cooldown); hay $dryrun"
    Assert ($logText -match 'DRYRUN code=cyber_policy texto=continue') 'DRYRUN registra codigo y respuesta (default de fabrica continue)'
    Assert ($logText -match [regex]::Escape('suprimido (cooldown/rafaga)')) 'segunda copia del evento suprimida por cooldown'
    Assert ($logText -notmatch 'AUTORESPOND code=') 'dry_run no envio nada real (sin AUTORESPOND en log)'

    # C1: la historia del rollout pre-llenado ANTES del arranque no dispara nada
    # (cuenta solo MATCH -> autorespond; "-> suprimido" es el dedup esperado)
    $nAutorespond = ([regex]::Matches($logText, 'MATCH code=\S+ file=\S+ -> autorespond')).Count
    Assert ($nAutorespond -eq 1) "unico MATCH -> autorespond, y del rollout nuevo (offsets al arranque, C1); hay $nAutorespond"
    Assert ($logText -notmatch 'rollout-historic') 'el rollout pre-llenado no genera MATCH/DRYRUN por su historia (C1)'
}
finally {
    # garantia: ningun daemon temporal queda vivo, pase lo que pase
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill(); [void]$proc.WaitForExit(3000) } catch { }
    }
}

# limpieza del temp solo si todo pass; si fallo, se conserva para depurar
if ($script:Failures -eq 0) {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } catch { }
    Write-Host '  (temp limpiado)'
}
else {
    Write-Host "  (temp conservado para depurar: $root)"
    $errDump = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
    if ($errDump) { Write-Host "  stderr daemon: $errDump" }
}

Write-Host "== Resultado E2E: $($script:Checks - $script:Failures)/$script:Checks ok, $script:Failures fallos =="
if ($script:Failures -gt 0) { exit 1 }
exit 0

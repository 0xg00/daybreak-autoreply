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
$watchPath = Join-Path $PSScriptRoot '..\watch.ps1'
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
Assert (($merged.cooldown_s -eq 5) -and ($merged.send_text -eq '/goal resume') -and ($merged.dry_run -eq $true)) 'Load-Config mergea defaults'
Assert (($merged.responses['context_window_exceeded'] -eq '/compact') -and ($merged.watch_codes.Count -eq 3)) 'Load-Config responses hashtable + watch_codes'
Assert (($missing.cooldown_s -eq 60) -and ($missing.sessions_dir -like '*\.codex\sessions')) 'Load-Config defaults si falta archivo'

# T8 Write-Log: append con timestamp ISO
$tmplog = Join-Path $d 'test-watchdog.log'
Write-Log 'evento de prueba' @{ log_file = $tmplog }
$logLine = Get-Content $tmplog -Raw
Assert (($logLine -match '\d{4}-\d{2}-\d{2}T') -and ($logLine -match 'evento de prueba')) 'Write-Log append con timestamp ISO'

# T9 burst: permitido tras cooldown con historia bajo el limite
$h.Clear(); $h.Add((Get-Date).AddMinutes(-2))
Assert ((Test-BurstAllowed (Get-Date) $h $cfg).Allowed) 'rafaga permite tras cooldown'

# Limpieza y resumen
try { Remove-Item $d -Recurse -Force -ErrorAction Stop } catch { }
Write-Host "== Resultado: $($script:Checks - $script:Failures)/$script:Checks ok, $script:Failures fallos =="
if ($script:Failures -gt 0) { exit 1 }
exit 0

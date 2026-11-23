# stop.ps1 — para el daemon de Daybreak Watchdog sin tocar nada mas.
# Run: pwsh -NoProfile -File stop.ps1            (lista lo que detendria, no hace nada)
#       pwsh -NoProfile -File stop.ps1 -Force    (detiene los procesos listados)
#
# Seguro por construccion: solo procesos cuyo CommandLine apunta a watch.ps1
# (jamas por nombre solo: un 'pwsh' generico puede ser cualquier cosa).
# Exit 1 si no hay nada que parar o si algun Stop falla.

param([switch]$Force)

$ErrorActionPreference = 'Stop'

# Solo shells de PowerShell, y dentro de ellos solo CommandLine que apunta a
# ESTE watch.ps1 (I3): la ruta absoluta resuelta de la carpeta del script o,
# como fallback para arranques relativos (`pwsh -File .\watch.ps1` desde la
# carpeta del proyecto), watch.ps1 como palabra delimitada (inicio de palabra
# que no sea parte de otro nombre + fin de palabra). El ancla evita falsos
# positivos: 'mywatch.ps1', 'watch.ps1.bak' o un 'Get-Content mywatch.ps1'
# ya no casan. Se excluye el propio proceso de stop.ps1 ($PID) por si su linea
# de comando llegara a mencionar watch.ps1: un script no debe matarse a si mismo.
$watchPath   = Join-Path $PSScriptRoot 'watch.ps1'
$watchAbs    = try { (Resolve-Path -LiteralPath $watchPath -ErrorAction Stop).Path } catch { $watchPath }
$watchRegex  = '(?i)({0}|(?<![\w.\-])watch\.ps1(?=["''\s]|$))' -f [regex]::Escape($watchAbs)

$targets = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop |
    Where-Object { $_.ProcessId -ne $PID -and ([string]$_.CommandLine) -match $watchRegex })

if ($targets.Count -eq 0) {
    Write-Host 'No hay ningun proceso de Daybreak Watchdog (watch.ps1) en ejecucion.'
    exit 1
}

if (-not $Force) {
    # modo listado (estilo -WhatIf): muestra lo que detendria y no toca nada
    Write-Host ("Se encontraron {0} proceso(s) de Daybreak Watchdog:" -f $targets.Count)
    foreach ($t in $targets) {
        Write-Host ("  PID {0}  {1}" -f $t.ProcessId, $t.CommandLine)
    }
    Write-Host 'Sin -Force no se ha detenido nada. Ejecuta: pwsh -NoProfile -File stop.ps1 -Force'
    exit 0
}

$failed = 0
foreach ($t in $targets) {
    try {
        Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
        Write-Host ("Detenido PID {0}" -f $t.ProcessId)
    }
    catch {
        $failed++
        Write-Warning ("No se pudo detener PID {0}: {1}" -f $t.ProcessId, $_.Exception.Message)
    }
}

if ($failed -gt 0) { exit 1 }
exit 0

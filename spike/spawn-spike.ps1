# Spike supervivencia: hook SessionStart que lanza un hijo detached y muere.
# Descarta stdin, arranca heartbeat.ps1 hidden, guarda su PID, exit 0.
$ErrorActionPreference = 'Stop'
try { [void]([Console]::In.ReadToEnd()) } catch { }

$dir = $PSScriptRoot
$child = Start-Process -FilePath 'pwsh' -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $dir 'heartbeat.ps1')
) -WindowStyle Hidden -PassThru

try {
    Set-Content -LiteralPath (Join-Path $dir 'spike-child.pid') -Value $child.Id -Encoding utf8
} catch { }
exit 0

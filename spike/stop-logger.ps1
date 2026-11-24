# Daybreak spike: registra el payload JSON que Codex envia al hook Stop.
# Log-only: no devuelve decision ni systemMessage -> Codex sigue su flujo
# normal. Cero efectos sobre la sesion. Reversible: quitar el registro en
# ~/.codex/hooks.json y borrar este archivo.
$ErrorActionPreference = 'Stop'

$log = Join-Path $PSScriptRoot 'stop-payloads.log'

try {
    $raw = [Console]::In.ReadToEnd()
} catch {
    $raw = "<stdin-error: $($_.Exception.Message)>"
}

$entry = "`n===== $(Get-Date -Format o) =====`n$raw"

try {
    # valvula: rotar si pasa de 5 MB (conservar solo una generacion .old)
    if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 5MB)) {
        Move-Item -LiteralPath $log -Destination "$log.old" -Force
    }
    Add-Content -LiteralPath $log -Value $entry -Encoding utf8
} catch {
    # nunca romper el turno del usuario por un fallo de log
}

exit 0

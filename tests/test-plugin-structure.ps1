# Valida la estructura del plugin daybreak-autoreply (manifest, hooks,
# scripts, commands, config por defecto). Run: pwsh -File tests/test-plugin-structure.ps1
$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Failures = 0

function Assert($cond, $name) {
    $script:Checks++
    if ($cond) { Write-Host "  ok   $name" } else { $script:Failures++; Write-Host "  FAIL $name" }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

Write-Host "== Estructura plugin daybreak-autoreply =="

# manifest
$manifestPath = Join-Path $root '.claude-plugin\plugin.json'
Assert (Test-Path $manifestPath) '.claude-plugin/plugin.json existe'
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert ($manifest.name -eq 'daybreak-autoreply') "name = daybreak-autoreply (actual: $($manifest.name))"
    Assert ($manifest.version) 'version presente'
    Assert ($manifest.description -and $manifest.description.Length -gt 0) 'description no vacia'
    Assert ($manifest.description -match 'Windows') 'description declara Windows-only'
}

# hooks
$hooksPath = Join-Path $root 'hooks\hooks.json'
Assert (Test-Path $hooksPath) 'hooks/hooks.json existe'
if (Test-Path $hooksPath) {
    $hooks = Get-Content $hooksPath -Raw -Encoding utf8 | ConvertFrom-Json
    $ss = $hooks.hooks.SessionStart
    Assert ($null -ne $ss) 'SessionStart definido'
    if ($ss) {
        $handler = @($ss[0].hooks)[0]
        Assert ($handler.type -eq 'command') 'handler type=command'
        Assert ($handler.command -match 'ensure-daemon\.ps1') 'comando referencia ensure-daemon.ps1'
        Assert ($handler.command -match '\$\{CLAUDE_PLUGIN_ROOT\}') 'comando usa ${CLAUDE_PLUGIN_ROOT}'
    }
}

# scripts
Assert (Test-Path (Join-Path $root 'scripts\watch.ps1')) 'scripts/watch.ps1 existe'
Assert (Test-Path (Join-Path $root 'scripts\stop.ps1')) 'scripts/stop.ps1 existe'
Assert (Test-Path (Join-Path $root 'scripts\ensure-daemon.ps1')) 'scripts/ensure-daemon.ps1 existe'

# commands
foreach ($c in 'status', 'test', 'stop', 'start', 'set') {
    Assert (Test-Path (Join-Path $root "commands\daybreak-$c.md")) "commands/daybreak-$c.md existe"
}

# config por defecto (fuente que Initialize-PluginData copiara a PLUGIN_DATA)
$cfgPath = Join-Path $root 'config.json'
Assert (Test-Path $cfgPath) 'config.json existe'
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($code in 'cyber_policy', 'usage_limit_exceeded', 'context_window_exceeded') {
        Assert ($null -ne $cfg.responses.$code) "responses.$code presente"
    }
    Assert ($cfg.send_text -eq 'continue') 'send_text = continue (default de fabrica)'
    Assert ($cfg.responses.cyber_policy -eq 'continue') 'cyber_policy -> continue'
    Assert ($cfg.responses.context_window_exceeded -eq '/compact') 'context_window_exceeded -> /compact'
    Assert ($cfg.dry_run -eq $false) 'dry_run = false (activo por defecto, requisito del socio)'
    Assert ($cfg.delivery -eq 'queue') 'delivery = queue (adenda v0.2)'
    Assert ($cfg.delay_s -eq 3) 'delay_s = 3'
    Assert ($cfg.cooldown_s -eq 0) 'cooldown_s = 0 (sin cooldown, peticion del socio)'
    Assert ($cfg.max_burst -eq 0) 'max_burst = 0 (sin maximo, peticion del socio)'
    Assert ($null -eq $cfg.sessions_dir) 'sessions_dir NO en config por defecto (portabilidad: el default de codigo usa $env:USERPROFILE; una ruta absoluta aqui zumba el plugin en otros PCs)'
}

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $($script:Failures) de $($script:Checks) asserts fallaron" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: $($script:Checks)/$($script:Checks) asserts ok" -ForegroundColor Green
exit 0

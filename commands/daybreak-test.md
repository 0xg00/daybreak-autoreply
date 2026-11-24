---
description: Test sandbox del motor Daybreak (DRYRUN, sin teclas reales)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

!`pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/daybreak-cli.ps1" test`

Ejecuta el E2E sandbox del plugin (directorio temporal aislado, dry_run forzado, sin tocar `~/.codex/sessions` ni enviar teclas). Presenta el resumen de asserts y la línea `exit=0` en un bloque de código. Si algún assert falla, muéstralo completo, sin resumir.

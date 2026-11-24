---
description: Reactivar Daybreak (quita el flag disabled y arranca el daemon)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

!`pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/daybreak-cli.ps1" start`

Muestra la salida del CLI tal cual (línea RUNNING con PID). Si no aparece RUNNING, sugiere ejecutar `/daybreak-status` para diagnóstico.

---
description: Apagar Daybreak de forma persistente (flag disabled)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

!`pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/daybreak-cli.ps1" stop`

Muestra la salida del CLI tal cual. Recuerda en una línea que la reactivación es con `/daybreak-start` (el apagado sobrevive a sesiones nuevas).

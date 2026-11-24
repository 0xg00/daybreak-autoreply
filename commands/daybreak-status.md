---
description: Estado del daemon Daybreak (PID, uptime, config, últimos disparos)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

!`pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/daybreak-cli.ps1" status`

Renderiza la salida como una tabla Markdown compacta con dos columnas (campo, valor) si el daemon está RUNNING, o un bloque de cita con NOT RUNNING y la causa (disabled flag / sin arrancar). Lista los últimos eventos tal cual, sin prosa extra.

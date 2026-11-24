---
description: Show Daybreak daemon status (PID, uptime, config, last events)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

Render the output as a compact two-column Markdown table (field, value) if the daemon is RUNNING, or a quote block with NOT RUNNING and the cause (disabled flag / not started). List the last events verbatim, no extra prose.


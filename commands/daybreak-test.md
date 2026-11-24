---
description: Run Daybreak engine sandbox test (DRYRUN, no real messages)
disable-model-invocation: true
allowed-tools: Bash(pwsh:*)
---

Runs the plugin's sandbox E2E (isolated temp dir, forced dry_run, never touches ~/.codex/sessions and sends nothing real). Show the assert summary and the xit=0 line in a code block. If any assert fails, show it in full.


# Scripts/Performance

winGod layer. Not upstreamed, and not referenced by any file outside this
folder.

| File | Does |
|---|---|
| `Logging.ps1` | structured run log: JSONL, text, console, rotation, redaction |
| `Audit-System.ps1` | read-only collectors plus the idle sampler and report export |
| `Invoke-WinGodAudit.ps1` | entry point, wires the log to the audit |

Planned:

| File | Does |
|---|---|
| `Compare-Baseline.ps1` | delta report between two captures |
| `Get-ServiceState.ps1` | read start mode and status per service |
| `Set-ServiceState.ps1` | apply start mode, honoring `-WhatIf`, recording previous state |
| `Export-RevertManifest.ps1` | write the revert manifest for a run |
| `Invoke-Revert.ps1` | undo changes from a manifest, one by one |

Rules for this folder:

1. Read-only by default. Anything that writes requires `-Confirm` or an explicit
   profile entry.
2. Every write records the previous state before touching anything.
3. No dependency on files outside this folder, except read access to
   `Config/Features.json`.
4. Tests live in `Tests/`, one file per module.
5. PowerShell 5.1 only. No ternary, no `??`, no `-Parallel`.
6. Counters come from CIM raw perf classes, never `Get-Counter`. Counter names
   are localized; raw class property names are not.

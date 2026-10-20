# Scripts/Performance

winGod layer. Not upstreamed, and not referenced by any file outside this
folder except the CLI dispatch in `Win11Debloat.ps1`.

Planned modules:

| File | Does |
|---|---|
| `Audit-System.ps1` | read-only inventory: processes, services, tasks, UWP background, startup entries |
| `Measure-Idle.ps1` | fixed-window capture of RAM, CPU, disk writes, handles, connections |
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
4. Tests live in `Tests/` like upstream, one file per module.

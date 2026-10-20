# Risk matrix

What each change costs. Tiers 0-1 keep servicing; tier 2 does not.

## Tier 0 - safe

| Change | Breaks | Reversible |
|---|---|---|
| Provisioned Appx removal | Some apps reinstall from Store unless Store is removed too | yes, re-add package |
| Consumer features policy | none observed | yes |
| Sponsored app suggestions off | none | yes |
| Scheduled task removal (telemetry/CEIP) | Nothing user-facing | yes, task XML is restorable |
| Reserved storage off | May reduce update headroom | yes |
| BitLocker device encryption off | No automatic device encryption | yes |

## Tier 1 - lean

| Change | Breaks | Reversible |
|---|---|---|
| `DiagTrack` disabled | Diagnostics data unavailable for troubleshooting | yes |
| `WSearch` disabled | Start menu search slower on first query; Outlook search broken; no file content index | yes, index rebuilds |
| `Spooler` disabled | **No printing** | yes |
| `WerSvc` disabled | No crash dumps, some installers fail on error reporting | yes |
| `TabletInputService` disabled | Touch keyboard and handwriting degrade | yes |
| Edge removed | No browser if no replacement; apps relying on `Microsoft-Edge-Webview` fail | reinstall Edge |
| Widgets platform removed | No widgets panel | yes |

## Tier 2 - core (destructive, unsupported)

| Change | Breaks | Reversible |
|---|---|---|
| Defender component removal | No AV, Windows Security pages broken, tamper protection gone, enterprise compliance checks fail | **no** |
| Windows Update removal | No security patches, no .NET/servicing stack updates, no feature enable, `winget`/MSIX dependency installs may fail, no driver updates | **no** |
| WinSxS trim | DISM and SFC stop working, no language packs, no optional features, no update install | **no** |
| WinRE removal | No recovery environment | no |
| Component cleanup `/ResetBase` | Installed updates can no longer be uninstalled | no |

## Standing warnings

1. A tier-2 image without Windows Update never receives a security fix. It is a
   permanently known-vulnerable machine. The build tool prints this on every
   tier-2 run and requires an explicit flag.
2. Removing Defender without a third-party AV leaves the machine unprotected.
   Not a configuration opinion; a factual outcome.
3. Deletion of the `UsoSvc` and `WaaSMedicSvc` service keys is the common
   "kill Windows Update" trick. It survives reboots and blocks re-enablement,
   which also blocks any future attempt to restore servicing without a reinstall.
4. Any change that removes a component cannot be undone by a profile change.
   Rebuild from the source ISO.

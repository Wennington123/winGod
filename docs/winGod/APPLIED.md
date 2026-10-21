# winGod applied machine profile

The exact set of changes applied to this machine (Windows 10, build 19044)
during the winGod optimization pass, with the revert path for each group.
This is the reference for what "the lean profile" means in practice.

## Services

| Service | Before | After | Revert |
| --- | --- | --- | --- |
| SysMain (Superfetch) | Running / Auto | Stopped / Disabled | `sc config SysMain start=auto; sc start SysMain` |
| WSearch (Windows Search) | Running / Auto (Delayed) | Stopped / Disabled | `sc config WSearch start=delayed-auto` |
| DiagTrack (Connected UX / Telemetry) | Running / Auto | Stopped / Disabled | `sc config DiagTrack start=auto` |
| WinDefend | Running / Auto | Stopped / Manual (+ registry policy) | Remove the Defender policies below and `sc start WinDefend` |
| wuauserv (Windows Update) | Running / Auto | Manual (triggered only) | `sc config wuauserv start=auto` |
| ClickToRunSvc (Office) | — | **Kept** Running / Auto (needed by Office apps) | — |
| Spooler (Printing) | — | **Kept** Running / Auto | — |

## Registry tweaks applied (from this repo's Regfiles)

Applied via `reg import` — revert with the matching file from
[Regfiles/Undo](../Regfiles/Undo) or `reg delete`.

### Telemetry / privacy / AI
- Disable_Telemetry (AllowTelemetry 0, Advertising ID off, tailored experiences off, activity history off, feedback off, Edge diagnostics off)
- Disable_Bing_Cortana_In_Search
- Disable_Copilot, Disable_AI_Recall, Disable_Click_to_Do, Disable_AI_Service_Auto_Start
- Disable_Location_Services, Disable_Find_My_Device
- Disable_Delivery_Optimization (update sharing off)

### Windows Update
- Disable_Update_ASAP, Prevent_Auto_Reboot, Disable_Device_Auto_App_Download

### Visual / background load
- Disable_Animations, Disable_Transparency
- Disable_Storage_Sense, Disable_Game_Bar_Integration, Disable_DVR
- Disable_Notifications
- Disable_Snap_Assist, Disable_Snap_Layouts, Disable_Window_Snapping
- Disable_Share_Drag_Tray, Disable_Sticky_Keys_Shortcut

### Display
- Monitor/sleep/hibernate timeouts set to **never** via `powercfg /change`:
  `monitor-timeout-ac/dc 0`, `standby-timeout-ac/dc 0`, `hibernate-timeout-ac/dc 0`
  (revert: `powercfg /change monitor-timeout-ac 10` and the sleep values of choice)

## Apps and tools removed
- OneCommander (scoop)
- Flow Launcher (scoop) — was also the shell override in `HKCU Winlogon\Shell`, now removed
- WSL + VirtualMachinePlatform features disabled, all distro/context-menu residue removed

## Applications kept on purpose
- Spooler (printing), ClickToRunSvc (Office), Windows Defender UI stubs
- Flow Launcher replaced by the Windows default Start/Win key (no launcher installed)

## Known upstream-test failure (not ours)
- `Remove-SelectedApps.Tests.ps1` fails on non-English Windows: the test
  matches the English exception text ("Value was either too large or too
  small") while a pt-BR system raises the localized message.

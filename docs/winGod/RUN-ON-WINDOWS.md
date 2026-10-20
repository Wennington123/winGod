# Running the audit on a real Windows machine

Read-only. Nothing is changed on the system. It writes files and exits.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (built in). PowerShell 7 also works.
- Administrator recommended, not required. Without it, Appx collection falls
  back to the current user and the log says so.

## Get the code

```powershell
git clone https://github.com/Wennington123/winGod.git
cd winGod
```

No modules to install. No dependencies.

## Run

Fast pass, about 20 seconds:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Performance\Invoke-WinGodAudit.ps1 -Quick
```

Full pass with a two-minute idle window and Appx data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Performance\Invoke-WinGodAudit.ps1 -IdleSeconds 120 -IncludeApps
```

Same but scrubbed for sharing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Performance\Invoke-WinGodAudit.ps1 -IdleSeconds 120 -IncludeApps -Redact
```

Deep log, every collector step, useful when something fails:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Performance\Invoke-WinGodAudit.ps1 -IdleSeconds 120 -IncludeApps -Level Trace
```

## Before you run it

- Reboot, wait until the desktop is fully settled, then wait two more minutes.
- Close browsers, chat clients and anything that syncs. They are part of the
  measurement otherwise.
- Do not touch the mouse or keyboard during the idle window. Input wakes things
  up and inflates CPU.

## Where the files land

Default root: `%LOCALAPPDATA%\winGod\audit`

```
audit\
  <run-id>\
    summary.md      human report, start here
    audit.json      full dataset
  logs\
    <run-id>\
      run.jsonl     one JSON object per event
      run.log       same events, aligned for reading
      run.meta.json tool version, host, PowerShell version
```

Override the root with `-OutputPath D:\winGod-audit`.

## What the numbers mean

| Metric | Meaning |
|---|---|
| `used_ram_mb` | total physical memory minus free physical memory |
| `cpu_pct` | mean busy time across logical processors |
| `disk_write_bytes` | physical disk write bytes per second, `_Total` instance |
| `private_mb` | per-process private committed memory |
| `working_set_mb` | per-process resident memory, includes shared pages |
| `handles` | kernel handles held by all processes |

Caveats worth knowing before drawing conclusions:

- Used RAM includes the standby list. Trimming it looks like a win and makes
  the machine slower. The audit reports it, it does not celebrate it.
- First sample of every idle window is a warm-up and has no CPU value on
  purpose. Deltas need two reads.
- 5 seconds is not a measurement. Two minutes is the minimum for a comparison.
- Windows Server runners and VMs have no shell processes, so their numbers are
  not comparable to a desktop.

## If something fails

The audit never aborts on a single collector. `summary.md` lists failed
collectors at the top, and `run.jsonl` has the reason under `collector.<name>`.

Common ones:

| Symptom | Cause |
|---|---|
| `appx` section missing or scope `current-user` | not elevated |
| `network` failed | `Get-NetTCPConnection` unavailable (very old build) |
| `tasks` failed | `ScheduledTasks` module blocked by policy |
| `startup` partial | one registry Run key denied |

Re-run with `-Level Trace` and send `run.jsonl`.

## What to send back

`summary.md`, `audit.json` and `run.jsonl`.

`-Redact` removes the user profile path, the user name, the computer name and
MAC addresses. It does **not** remove process names, service names, Appx package
names or remote addresses of established connections. Review `run.jsonl` before
posting it publicly.

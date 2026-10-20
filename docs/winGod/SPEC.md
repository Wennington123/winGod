# SPEC

## 1. Problem

Windows 11 spends RAM, CPU and disk on work the user did not ask for:
telemetry, consumer app provisioning, background app refresh, search indexing,
update orchestration, error reporting. The goal is to remove that idle cost
without changing how Windows looks or how drivers work.

## 2. Scope

### In

- Offline customization of an official `install.wim` / `install.esd`.
- Declarative profiles: data, not imperative scripts.
- Separate modules, each opt-in.
- A measurement harness that proves or refutes every claim.
- Reproducibility: source hash + profile hash + tool version in the output
  manifest.

### Out

- Shipping or hosting modified Windows images.
- Activation, licensing bypass, KMS/MAK anything.
- Driver injection or replacement.
- Shell, taskbar, Start menu or visual changes.
- Removing the servicing stack in tiers 0 and 1.
- Online (post-install) tweaks in v1.

## 3. Principles

1. **Disable before delete.** A disabled service is reversible. A removed
   component is not.
2. **Every change is a record.** No tweak without: id, tier, mechanism,
   what it breaks, and a measurement.
3. **The shell is a contract.** Nothing that changes rendering, input, or
   window management.
4. **No claim without a baseline.** If it is not measured, it does not ship.
5. **Tier is a hard gate.** Tier 0 changes must run unmodified inside tier 2.

## 4. Architecture

```
winGod/
  build/        orchestrator + DISM plumbing
  modules/      one file per concern, each with a dry-run
  profiles/     tier-0, tier-1, tier-2 profile definitions
  measure/      baseline capture + comparison
  guard/        blocklists of components that must never be removed
  docs/         this spec, perf model, risk matrix
  tests/        profile schema validation, guard tests
```

### 4.1 Phases

| Phase | Runs on | Does |
|---|---|---|
| `prepare` | Windows host | verify ISO, hash it, copy to scratch |
| `mount` | Windows host | DISM mount target index |
| `apply` | Windows host | run enabled modules in order |
| `cleanup` | Windows host | component cleanup, only if profile allows |
| `unmount` | Windows host | commit, export WIM |
| `package` | Windows host | rebuild ISO (oscdimg) |
| `measure` | target VM | capture baseline vs result |

Phase order is fixed. Modules cannot reorder phases.

### 4.2 Module contract

Each module exports:

```powershell
function Invoke-WinGodModule {
    param(
        [Parameter(Mandatory)] [string]   $Mount,
        [Parameter(Mandatory)] [hashtable] $Config,
        [switch] $DryRun
    )
}
```

Rules:

- Idempotent.
- Returns a result object: `{ Module, Changes[], Skipped[], Warnings[] }`.
- Never writes outside `$Mount` except to the result stream.
- `-DryRun` resolves every change and prints it without touching the image.
- Fails closed: unknown config key is an error, not a warning.

### 4.3 Modules

| Module | Tier | Concern |
|---|---|---|
| `appx` | 0 | provisioned packages |
| `telemetry` | 0 | policies, DiagTrack, dmwappushservice |
| `tasks` | 0 | scheduled task definitions |
| `unattend` | 0 | OOBE, local account, reserved storage |
| `edge` | 1 | Edge, WebView2 decision |
| `services` | 1 | service start modes |
| `search` | 1 | Windows Search indexing |
| `spooler` | 1 | print spooler, opt-in |
| `wu` | 2 | Windows Update |
| `defender` | 2 | Defender |
| `components` | 2 | package removal, WinSxS trim |

### 4.4 Guard

`guard/never-remove.json` lists components whose removal is blocked by the
build tool, regardless of profile. The list is populated from real ISO
inventory, never from guesswork. Minimum content:

- Anything whose package name matches the servicing stack.
- Anything matching the shell / shell experience.
- Anything matching the client CBS / component servicing base.

A tier-2 profile that names a guarded component fails the build.

## 5. Profile schema

```json
{
  "name": "lean",
  "tier": 1,
  "source": { "iso_sha256": "<required at build time>" },
  "modules": {
    "appx":      { "remove": ["Clipchamp.Clipchamp", "Microsoft.BingNews"] },
    "telemetry": { "allow_telemetry": 0 },
    "tasks":     { "remove": ["\\Microsoft\\Windows\\Application Experience\\*"] },
    "services":  { "disable": ["DiagTrack", "WerSvc"], "manual": ["WSearch"] },
    "edge":      { "mode": "remove", "webview2": "keep" },
    "wu":        { "mode": "notify" },
    "defender":  { "mode": "keep" }
  }
}
```

- Unknown module: error.
- Unknown key inside a module: error.
- Tier gate: a module above the profile tier is an error unless
  `--allow-destructive` is passed.

## 6. Reproducibility

Output manifest, written next to the produced ISO:

```json
{
  "winGod": "0.1.0",
  "source_iso_sha256": "...",
  "profile": "lean",
  "profile_sha256": "...",
  "modules": [{ "name": "appx", "changes": 46 }],
  "warnings": []
}
```

Two runs of the same input must produce the same manifest. If they do not, it
is a bug.

## 7. v1 exit criteria

1. `profiles/tier0.json` and `profiles/tier1.json` build on a clean official
   ISO without manual intervention.
2. Every module has a passing dry-run test.
3. The measurement harness produces a before/after report for a VM.
4. The guard blocks a deliberately bad tier-2 profile.
5. The produced image boots, installs, reaches the desktop, and runs a
   driver-dependent workload.

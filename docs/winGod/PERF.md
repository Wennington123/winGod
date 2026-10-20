# Performance model

All numbers here are **projections**, not measurements. They exist so the
harness has something to falsify. Every row must be replaced with a measured
value before it is shown to a user.

## 1. Baseline assumptions

- Windows 11 24H2, clean install, local account, no third-party drivers.
- VM: 4 vCPU, 4 GB RAM, 64 GB virtio disk, no GPU passthrough.
- Measurement 10 minutes after first desktop, no user input, network up.
- Stock idle: ~2.2-3.5 GB used, ~140-200 processes, 90-140 services running,
  1.5-3% CPU average.

## 2. Projected effect by tier

| Tier | Used RAM | Processes | Boot time | Idle CPU | ISO size |
|---|---|---|---|---|---|
| stock | 2.2-3.5 GB | 140-200 | baseline | 1.5-3% | 5.0-6.5 GB |
| 0 safe | -150 to -400 MB | -30 to -60 | -1 to -3 s | -0.3 to -0.8 pp | -0.3 to -0.8 GB |
| 1 lean | -350 to -800 MB | -50 to -90 | -2 to -5 s | -0.5 to -1.5 pp | -0.5 to -1.2 GB |
| 2 core | -600 to -1200 MB | -70 to -120 | -3 to -8 s | -0.8 to -2.0 pp | -2.0 to -3.5 GB |

The tier-2 RAM range is wider because it depends on how much of the component
store is trimmed.

## 3. Where the numbers come from

Expected contribution, by change:

| Change | RAM | Processes | Confidence |
|---|---|---|---|
| Consumer Appx (46 prefixes) | 80-250 MB | 15-35 | medium |
| Widgets platform removal | 60-150 MB | 3-6 | medium |
| Copilot removal / policy off | 40-120 MB | 1-3 | low |
| Telemetry policies + DiagTrack | 20-60 MB | 1-2 | medium |
| Scheduled task removal | 10-40 MB | 0-2 | low |
| Edge background + update services | 30-90 MB | 4-8 | medium |
| Search indexing off | 60-140 MB | 1-2 | medium |
| Error reporting off | 10-30 MB | 1-2 | low |
| Defender off (tier 2) | 150-300 MB | 3-5 | medium |
| Windows Update off (tier 2) | 20-60 MB | 1-3 | low |
| Component store trim | 0 | 0 | n/a |

Ranges overlap because Windows makes different choices per SKU, per hardware
topology, and per update level.

## 4. What is deliberately not claimed

- **Standby list / memory compression.** Trimming the standby list lowers
  "used RAM" and makes the machine slower. Not a win. Not counted.
- **SysMain (Superfetch) removal.** Same reason. Cache is not waste.
- **Pagefile tuning.** Moves cost, does not remove it.
- **"Faster" without a workload.** Boot time is measured; app launch claims
  are only made with a fixed benchmark.

## 5. Measurement protocol

Fixed, or the numbers mean nothing.

### 5.1 Environment

- QEMU/KVM or Hyper-V, 4 vCPU, 4 GB, virtio/SCSI, no dynamic memory.
- Fresh install per run, same ISO, same profile.
- Network up but no user account signed into any cloud service.
- No updates applied after install.

### 5.2 Capture

Ten minutes after the desktop appears, then a 5-minute sampling window:

| Metric | Source |
|---|---|
| Used RAM | `Memory\Available MBytes`, subtracted from total |
| Process count | `Get-Process` |
| Service count | `Get-Service` where `Running` |
| Idle CPU | `Processor(_Total)\% Processor Time`, 5 min mean |
| Disk writes | `PhysicalDisk(_Total)\Disk Bytes/sec`, 5 min mean |
| TCP connections | `Get-NetTCPConnection -State Established` |
| Boot time | Event ID 100, `Microsoft-Windows-Diagnostics-Performance/Operational` |
| Handle count | `Get-Process | Measure-Object HandleCount -Sum` |

### 5.3 Runs

Three boots per configuration. Report median. Discard a run if the VM host was
under unrelated load.

### 5.4 Report

The harness emits JSON plus a table diffing stock against each profile, with
per-metric deltas and the raw medians. A change that cannot be shown in the
table is not a feature.

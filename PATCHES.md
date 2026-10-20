# Upstream patch map

Everything here exists so the fork stays cheap to rebase and so generic
improvements can go upstream as focused pull requests.

## Layers

| Layer | Lives in | Goes upstream |
|---|---|---|
| `core-additions` | new files, plus the points listed below | yes, as small PRs |
| `winGod-layer` | `Scripts/Performance/`, `docs/winGod/`, profiles | no |

Rule: a `core-additions` commit must not reference anything from the
`winGod-layer`. That keeps it cherry-pickable onto `upstream/master`.

## Upstream files touched

| File | Change | PR-able |
|---|---|---|
| `Scripts/Features/Telemetry-ScheduledTasks.ps1` | 13 additional telemetry tasks (8 -> 21) | yes |
| `Tests/Telemetry-ScheduledTasks.Tests.ps1` | catalog expectation updated | yes |
| `README.md` | fork banner prepended | no |
| `Win11Debloat.ps1` | new CLI switches (`-Audit`, `-Measure`, `-Revert`, `-Profile`) | no |
| `Scripts/Features/Invoke-Changes.ps1` | dispatch cases for the new modules | no |
| `Config/Features.json` | Performance category and feature entries | no |

Anything not listed above is a new file.

## Sending a PR upstream

```bash
git fetch upstream
git checkout -b pr/telemetry-task-catalog upstream/master
git cherry-pick <core-additions-commit>
git push origin pr/telemetry-task-catalog
```

PR body must state that it is part of a larger fork but is self-contained, and
must not mention tier gating, profiles or the measurement layer.

## Rebasing the fork

```bash
git fetch upstream
git rebase upstream/master
```

Expected conflicts are limited to the four upstream files above. If a conflict
appears anywhere else, a new file was modified and the layer boundary was
broken.

## Validation

Upstream tests are Pester. Run them on Windows:

```powershell
Invoke-Pester -Path ./Tests
```

No test may depend on `Scripts/Performance/`.

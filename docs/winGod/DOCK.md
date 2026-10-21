# winGod Dock

Barra dockada ao fundo do ecrã, no espírito do [lumabar](https://lumabar.xyz/docs):
relógio + data, CPU/RAM/disco, ícones de som e rede, tiles de apps pinados e um
**painel de personalização** (⚙ no fim da barra). 100% PowerShell + WPF, sem
rede, sem telemetria, sem contas.

Com o dock ativo a taskbar do Windows é **escondida por completo** (não só
auto-hide) e volta ao normal quando o dock para.

## Requisitos

- Windows 10/11 x64 (testado na build 19044, DPI 125%)
- PowerShell 5.1 (pré-instalado) com STA (padrão)
- GlazeWM: o dock é `WS_EX_TOOLWINDOW` + topmost re-asserted, fica fora do tiling

## Arrancar

```powershell
# No clone do repo
.\Scripts\Dock\Start-Dock.bat
# abrir com o painel de personalização já aberto
PowerShell -File .\Scripts\Dock\Invoke-WinGodDock.ps1 -OpenPanel
```

No primeiro arranque manual, o dock registra a Run key de auto-arranque:

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Run  ->  winGodDock
```

Arranques disparados pela Run key não re-registram nada (`-NoRunKey`).

## Painel de personalização

Clica no **⚙** no fim do dock (ou arranque com `-OpenPanel`):

- Widgets do dock: relógio, stats, apps pinados, ícones de som/rede
- Tema dark/glass, altura P/M/G, relógio 24h
- Auto-hide da barra (recolhe ao tirar o mouse) e esconder em fullscreen
- Editor de apps pinados (adicionar via diálogo de arquivos, remover com `-`)
- "Salvar e reiniciar" grava `Config/Dock.json` e refaz o dock na hora

## Configuração

`Config/Dock.json`:

| Campo | Default | Descrição |
| --- | --- | --- |
| `Height` | `L` | Altura da barra: `S` 40px, `M` 48px, `L` 56px |
| `Theme` | `glass` | `dark` ou `glass` |
| `Clock24h` | `true` | Formato do relógio |
| `Widgets` | clock, stats, appTiles, indicators | IDs: `clock`, `stats`, `appTiles`, `indicators` |
| `AutoHideBar` | `true` | Barra recolhe para uma tirinha quando o rato sai; hover no fundo desliza |
| `FullscreenHideBar` | `true` | Esconde durante apps/games em fullscreen borderless (janelas maximizadas não contam) |
| `PinnedApps` | `[]` | `{ "Name", "Path", "Args": [], "IconPath": "..." }`, env-vars expandidas |

## Estado interno

- `%LOCALAPPDATA%\winGod\dock\run.json` — PID/config do dock ativo
- `%LOCALAPPDATA%\winGod\dock\logs\` — `run.jsonl` + `run.log` (mesma infra do audit)

## Taskbar escondida: como funciona e riscos

Duas camadas:

1. `Scripts/Dock/Set-TaskbarAutoHide.ps1` ajusta o byte do auto-hide em
   `HKCU\...\StuckRects3\Settings` (byte 8: moderno `0x02`/`0x03`; legacy
   `0x78`/`0x79`) e reinicia o Explorer.
2. Enquanto o dock roda, a janela `Shell_TrayWnd` é **oculta de fato**
   (`ShowWindow`), com re-hide a cada 600ms — o hover no fundo não traz a
   taskbar de volta. No `-Stop`/kill a taskbar volta visível.

- Fallback: se o layout binário não bater, o valor não é escrito e o log avisa
- `-Status` mostra o estado sem alterar nada

## Limitações v1.1

- Ícone de apps com alias (ex.: `wt.exe`) usa `IconPath` — senão cai na letra
- Painel com widgets visuais simples (Screen Time, Pomodoro etc. ficam para v2)
- Multimonitor: usa apenas o ecrã primário
- CPU via WMI `Win32_PerfFormattedData_PerfOS_Processor` (independente de locale,
  amostra a cada 2s)

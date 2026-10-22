# Windows 11 Optimized Builder

Safety-first, reproducible custom Windows 11 media for programming and office work.

> **Status: Phase 0 — scaffold only.** No ISO has been built or certified. This project does not distribute Windows files; use an original ISO obtained directly from Microsoft.

## Goals
- Balanced performance, compatibility, security and repairability.
- Preserve Windows Update, Defender, Store, App Installer/winget, Terminal, PowerShell, WebView2, DISM/SFC, recovery, networking, VPN, WMI, Task Scheduler and servicing.
- Make removals explicit, reviewable and tested.
- Keep logs, build manifests and validation results.

## Current status
- [x] Initialize repository and safety policy
- [x] Add developer profile manifest and non-destructive preflight
- [ ] Audit supplied source code and licensing
- [ ] Add Windows-hosted PowerShell tests
- [ ] Validate in disposable VMs before release

## Requirements
- Windows host and PowerShell 5.1 or a supported version
- Administrator privileges for servicing
- Windows ADK Deployment Tools / compatible DISM
- Original Windows 11 ISO from Microsoft
- At least 25 GB free scratch space

## Preflight
Run PowerShell as Administrator:
```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Test-BuildEnvironment.ps1 -IsoPath "C:\ISO\Win11.iso"
```
This check does not modify Windows or create an ISO.

## Principles
1. Measure before removing; fewer processes does not automatically mean better performance.
2. Prefer supported policy/configuration to deleting system components.
3. Fail closed on missing tools, insufficient space or failed DISM operations.
4. Do not promise "zero telemetry" without evidence.
5. Do not bypass hardware/security requirements by default.
6. Never commit ISOs, mounted images, credentials or sensitive logs.

See [scope](docs/00-PROJECT-SCOPE.md), [safe defaults](docs/05-V2-SAFE-DEFAULTS.md), and [roadmap](docs/04-BACKLOG.md).

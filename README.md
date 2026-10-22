# Windows 11 Optimized Builder V1

A Windows-hosted builder for a conservative, developer/office-oriented Windows 11 image, based on the source project supplied for this repository.

> **Build status:** the V1 source bundle is available separately for download, but this repository's PR currently contains the scaffold and validation workflow. Do not treat the PR branch alone as a runnable builder until the source files are integrated. No Windows ISO is included or distributed.

## V1 profile
- Removes a bounded set of consumer/promotion apps.
- Preserves Windows Update, Defender, Store, App Installer/winget, Terminal, PowerShell, WebView2, servicing, recovery, networking, printing and Bluetooth.
- Hardware requirement bypass is opt-in only.
- OneDrive sync blocking is opt-in only.
- Does not disable `dmwappushservice` or alter undocumented Windows Update Orchestrator completion flags.
- Never uses DISM `/ResetBase`.

## Download and run
Download the complete source bundle from the conversation attachment named **windows-11-optimized-builder-v1.zip**. Extract the entire ZIP to a local folder, obtain an original Windows 11 24H2/25H2 ISO directly from Microsoft, and double-click `LAUNCH_TINY11.bat`. Windows will request administrator elevation. Select the source ISO and edition in the GUI.

Requirements: Windows PowerShell 5.1, administrator privileges, compatible Windows 11 DISM (10.0.26100+), and at least 20 GB free scratch space (40 GB recommended). If a compatible DISM is not available on the host, install Windows ADK Deployment Tools.

## Validation status
Static source checks are included in the bundle, but Windows-host execution, ISO bootability, feature-update and installed-system VM tests have not been run in this environment. Always test the resulting ISO in a disposable VM before physical installation.

## Project safety
Never commit ISO/WIM/ESD payloads, mounted images, credentials or sensitive logs. No "zero telemetry" guarantee is made; privacy settings reduce selected consumer/diagnostic features but cannot prove all outbound communication is eliminated.

See [project scope](docs/00-PROJECT-SCOPE.md), [safe defaults](docs/05-V2-SAFE-DEFAULTS.md), and [roadmap](docs/04-BACKLOG.md).

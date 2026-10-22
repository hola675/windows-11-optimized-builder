# Agent instructions

Before editing, read `docs/00-PROJECT-SCOPE.md` and `docs/05-V2-SAFE-DEFAULTS.md`, inspect relevant code/tests, state risks, make the smallest safe change, run available tests, and show the diff. Never claim Windows-host validation if it was not run on Windows.

Do not remove or disable Defender/Security, Windows Update, Store, App Installer/winget, Terminal, PowerShell, WebView2, Windows Installer, WMI, Task Scheduler, DISM, SFC, WinSxS, WinRE, networking/VPN, Credential Manager or servicing components without explicit authorization and compatibility evidence.

No random registry tweaks or copied debloat lists. Do not disable services just to reduce process count. Prefer policy to deletion. Check exit codes for DISM, reg.exe and oscdimg. Preserve source media and only clean workspaces created by the current run. Never commit generated ISOs or mounted images.

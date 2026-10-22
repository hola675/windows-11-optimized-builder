# Safe defaults

## Preserve by default
Windows Update and servicing; Defender and Windows Security; Store and App Installer/winget; Terminal and PowerShell; WebView2; DISM/SFC; Windows Installer; WMI; Task Scheduler; WinSxS; WinRE; networking, VPN, Bluetooth, printing, Credential Manager and common developer runtimes.

## Candidate consumer apps
Only remove apps when exact package identity is verified against the selected Windows build and tests prove dependencies remain intact. Display names are not stable package identifiers. Record skipped/missing packages.

## Privacy
Document controls individually with scope, reversibility and Windows edition/build. Do not promise "zero telemetry." Do not disable diagnostic/security services needed for updates, reliability or Defender.

## Unsupported hardware
Do not bypass requirements by default. Experimental switches must be opt-in and warn about support, update and security implications.

## Validation
Test OOBE, activation, Windows Update, Defender, Store, winget, PowerShell, Terminal, WebView2, network/VPN, printing, Bluetooth, sleep/resume, DISM health, SFC and WinRE after policy changes.

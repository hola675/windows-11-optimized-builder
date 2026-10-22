# V1 source bundle and safety status

The complete source bundle is distributed as a separate ZIP artifact; the current PR branch still contains the repository scaffold and is not independently runnable until all source modules are committed here.

The supplied V1 source has these explicit safe defaults:
- Hardware requirement bypass is opt-in through `-AllowUnsupportedHardware`.
- OneDrive sync blocking is opt-in through `-BlockOneDriveSync`.
- `dmwappushservice` is preserved.
- Undocumented Windows Update Orchestrator completion flags are not modified.
- DISM `/ResetBase` is prohibited.

Older historical decision entries may describe earlier behavior. This note and the current source code supersede conflicting historical entries.

No ISO is included. Use original Microsoft installation media, and test output in a disposable VM before installing on physical hardware. The build has not been run in a Windows host in this environment.

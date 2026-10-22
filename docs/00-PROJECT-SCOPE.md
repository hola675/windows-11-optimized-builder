# Project scope

## Objective
Build maintainable Windows 11 installation media for development and office productivity, balancing responsiveness, compatibility, security and repairability.

## In scope
- Validate Microsoft-provided media.
- Select edition and work directory.
- Apply a version-controlled conservative manifest.
- Use supported DISM servicing and create bootable media.
- Emit logs, manifest, hashes and validation summary.
- Test in disposable VMs before release.

## Out of scope for the first milestone
- Disabling security protections without authorization.
- Bypassing TPM, Secure Boot, CPU or other requirements by default.
- Removing servicing components or forcibly deleting system packages.
- Claiming zero telemetry.
- Bundling Microsoft binaries, keys, activation bypasses or Windows ISOs.

## Acceptance gates
1. Source ISO is recognized and untouched.
2. Build fails on missing tools, insufficient space or failed DISM operations.
3. Critical capabilities in AGENTS.md remain available.
4. OOBE, activation, updates, Defender, Store, winget, Terminal, networking, printing, Bluetooth, recovery and repair pass VM checks.
5. Build manifest and SHA-256 are recorded.
6. No release until test evidence is attached.

# User build guide (current status)

## Important status
The repository is being prepared. Until the audited builder source and its supporting files are present in the repository, there is no complete one-click ISO build in this repository. Do not treat the current scaffold as a finished installer.

## Intended user workflow
1. Download the project ZIP or a signed release ZIP.
2. Extract it to a short local path such as `C:\\Win11Builder` (not inside OneDrive or a network share).
3. Obtain an original Windows 11 ISO directly from Microsoft.
4. Right-click the launcher and choose **Run as administrator**.
5. Select the ISO and Windows edition in the builder UI.
6. Wait for DISM servicing and ISO creation to finish; retain the logs.
7. Test the output ISO in a disposable virtual machine before installing on physical hardware.

## Host requirements
- Supported Windows host; Windows PowerShell 5.1.
- Administrator privileges.
- Windows 11 ADK Deployment Tools (DISM and Oscdimg).
- At least 25 GB free scratch space; 40 GB or more is recommended.
- Source ISO should be an unmodified Microsoft ISO.

## Safety
- Back up important data before installing any custom Windows image.
- Do not install a custom ISO on your primary machine before VM testing.
- Do not bypass TPM/Secure Boot/CPU requirements unless you explicitly accept unsupported status.
- No ISO is produced by GitHub's Linux-hosted runner. The build and installation tests require Windows and original Microsoft media.

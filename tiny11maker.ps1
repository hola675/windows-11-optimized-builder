# Uncomment the line below to enable debugging
# Set-PSDebug -Trace 1

param (
    [string]$ScratchDisk,
    # wim (default): /Compress:max, mountable and verifiable. esd: /Compress:recovery, smaller but slow and not mountable.
    [ValidateSet('wim', 'esd')]
    [string]$InstallImageFormat = 'wim',
    # Enable .NET Framework 3.5 offline from the media's sources\sxs (off by default)
    [switch]$EnableNetFx3,
    # Optional local Administrators account created by the answer file (blank password, new one required at the next sign-in)
    [string]$LocalAccountName,
    # Unsupported hardware workarounds are opt-in; may affect support and updates.
    [switch]$AllowUnsupportedHardware,
    # Explicit opt-in for the existing OneDrive file-sync restriction.
    [switch]$BlockOneDriveSync
)

if (-not $ScratchDisk) {
    $ScratchDisk = $PSScriptRoot
}

function Test-ScratchDisk {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "ScratchDisk path is null or empty."
    }

    $driveRoot = (Split-Path -Path $Path -Qualifier) + '\'
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        throw "ScratchDisk drive does not exist: $driveRoot"
    }

    if ($Path.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) {
        throw "ScratchDisk must not be a volume root. Resolved to: $driveRoot"
    }

    $freeSpace = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq $driveRoot }).Free
    if ($freeSpace -lt 20GB) {
        throw "ScratchDisk drive $driveRoot has less than 20 GB free space. Free: $([math]::Round($freeSpace / 1GB, 2)) GB"
    }

    $testFile = Join-Path $Path ".__writetest_$(New-Guid)"
    try {
        Set-Content -LiteralPath $testFile -Value 'wave0a' -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $testFile)) {
            throw "ScratchDisk path is not writable: test file was not created."
        }
        Remove-Item -LiteralPath $testFile -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $testFile) {
            throw "ScratchDisk path is not writable: test file could not be deleted."
        }
    } catch {
        if (Test-Path -LiteralPath $testFile) {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
        throw "ScratchDisk path is not writable: $($_.Exception.Message)"
    }

    return $Path
}

function Assert-NativeCommandSucceeded {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Operation,
        [Parameter(Mandatory=$true)]
        [string]$Executable,
        [Parameter(Mandatory=$true)]
        [int]$ExitCode,
        [object]$Output
    )

    if ($ExitCode -ne 0) {
        $message = "$Operation failed. Executable: $Executable. Exit code: $ExitCode."
        if ($null -ne $Output) {
            $message += " Output: $(@($Output) -join "`n")"
        }
        throw $message
    }
}

$ScratchDisk = Test-ScratchDisk -Path $ScratchDisk

$buildError = $null
$buildException = $null
$cleanupErrors = @()

$installImageMountedByThisRun = $false
$bootImageMountedByThisRun = $false
$sourceIsoMountedByThisRun = $false

$loadedInstallHives = @()
$loadedBootHives = @()

$tiny11WorkspaceCreatedByThisRun = $false
$scratchDirCreatedByThisRun = $false
$dismScratchCreatedByThisRun = $false

function Unmount-ImageIfOwned {
    param(
        [string]$MountDir,
        [string]$ImageName,
        [ref]$OwnershipFlag,
        [switch]$ForceDiscard
    )

    if (-not $OwnershipFlag.Value) {
        Write-Host "SKIP: $ImageName was not mounted by this build."
        return
    }

    try {
        if ($ForceDiscard) {
            Write-Host "DISCARD: $ImageName (failure path)"
            Invoke-Dism -DismPath $dism.Path -Operation "unmount $ImageName (discard)" -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Discard')
        } else {
            Write-Host "COMMIT: $ImageName (success path)"
            Invoke-Dism -DismPath $dism.Path -Operation "unmount $ImageName (commit)" -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Commit')
        }

        $OwnershipFlag.Value = $false
        Write-Host "OK: $ImageName released."
    } catch {
        $script:cleanupErrors += "DISM unmount $ImageName exception: $($_.Exception.Message)"
    }
}

function Unload-OfflineHives {
    param(
        [array]$HiveAliases,
        [string]$Stage
    )

    # Unload in reverse order to respect any inter-hive dependencies
    for ($i = $HiveAliases.Count - 1; $i -ge 0; $i--) {
        $alias = $HiveAliases[$i]
        try {
            $unloadOutput = & 'reg' 'unload' "HKLM\$alias" 2>&1
            $unloadExitCode = $LASTEXITCODE

            if ($unloadExitCode -ne 0) {
                throw "reg unload $Stage $alias failed. Exit code: $unloadExitCode. Output: $unloadOutput"
            }
            Write-Host "OK: $Stage hive $alias unloaded."
        } catch {
            throw "reg unload $Stage $alias exception: $($_.Exception.Message)"
        }
    }
}

function Unload-RegistryHivesIfOwned {
    param(
        [array]$HiveAliases,
        [string]$Stage
    )

    foreach ($alias in $HiveAliases) {
        try {
            $unloadOutput = & 'reg' 'unload' "HKLM\$alias" 2>&1
            $unloadExitCode = $LASTEXITCODE

            if ($unloadExitCode -ne 0) {
                $script:cleanupErrors += "reg unload $Stage $alias failed. Exit code: $unloadExitCode. Output: $unloadOutput"
            } else {
                Write-Host "OK: $stage hive $alias unloaded."
            }
        } catch {
            $script:cleanupErrors += "reg unload $stage $alias exception: $($_.Exception.Message)"
        }
    }
}

function Dismount-IsoIfOwned {
    param(
        [string]$DrivePath,
        [string]$MountMode,
        [string]$ImagePath
    )

    if (-not $sourceIsoMountedByThisRun) {
        Write-Host "SKIP: Source ISO was not mounted by this build."
        return
    }

    if ($MountMode -ne 1) {
        Write-Host "SKIP: Source was user-supplied drive, not mounted ISO."
        return
    }

    try {
        Write-Host "Dismounting source ISO: $ImagePath (mounted at $DrivePath)"
        Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop | Out-Null
        Write-Host "OK: Source ISO dismounted."
    } catch {
        $script:cleanupErrors += "Dismount source ISO $ImagePath exception: $($_.Exception.Message)"
    }
}

function Test-EmptyBuilderWorkspace {
    param(
        [string]$Path
    )

    $workspaceItem = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $workspaceItem.PSIsContainer) {
        return $false
    }

    if (($workspaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 2)
    if ($entries.Count -ne 1) {
        return $false
    }

    $sourcesItem = $entries[0]
    if ($sourcesItem.Name -ne 'sources' -or -not $sourcesItem.PSIsContainer) {
        return $false
    }

    if (($sourcesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    $sourcesEntries = @(Get-ChildItem -LiteralPath $sourcesItem.FullName -Force -ErrorAction Stop | Select-Object -First 2)
    return $sourcesEntries.Count -eq 0
}

function Remove-ScratchWorkspaceIfOwned {
    param(
        [string]$ScratchDisk,
        [string]$WorkspaceName,
        [ref]$WorkspaceOwnerFlag
    )

    $targetPath = Join-Path $ScratchDisk $WorkspaceName

    if (-not (Test-Path -LiteralPath $targetPath)) {
        Write-Host "SKIP: $WorkspaceName does not exist."
        return
    }

    $driveRoot = (Split-Path -Path $ScratchDisk -Qualifier) + '\'
    $resolvedTarget = (Resolve-Path -LiteralPath $targetPath).Path
    $resolvedRoot = (Resolve-Path -LiteralPath $driveRoot).Path
    if (-not $resolvedTarget.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $script:cleanupErrors += "SAFETY: Refusing to delete $targetPath - not under scratch drive $driveRoot"
        return
    }

    if ($resolvedTarget.TrimEnd('\') -eq $resolvedRoot.TrimEnd('\')) {
        $script:cleanupErrors += "SAFETY: Refusing to delete volume root $driveRoot"
        return
    }

    if (-not $WorkspaceOwnerFlag.Value) {
        $script:cleanupErrors += "SAFETY: Refusing to delete $targetPath - not created by this run (no ownership)."
        return
    }

    try {
        Write-Host "Removing builder workspace: $targetPath"
        Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop | Out-Null
        $WorkspaceOwnerFlag.Value = $false
        Write-Host "OK: $WorkspaceName removed."
    } catch {
        $script:cleanupErrors += "Remove $WorkspaceName failed: $($_.Exception.Message)"
    }
}

Add-Type -assembly System.Windows.Forms

Import-Module -Name "$($PSScriptRoot -replace '\\', '/')/lib/tiny11utils.psm1"
Import-Module -Name "$($PSScriptRoot -replace '\\', '/')/lib/tiny11gui.psm1"

# Reject an unusable account name before elevation or any build work
if ($LocalAccountName) {
    Assert-LocalAccountName -Name $LocalAccountName
}

# Resources files
$ResIconPath = "$($PSScriptRoot -replace '\\', '/')/resources/T11M_icon.ico"
$ResSplashPath = "$($PSScriptRoot -replace '\\', '/')/resources/T11M_splash.png"

# GUI variables
$AppTitle = "Tiny11 Maker ~ Reforged Edition"
$AppVersion = "v2025.11.17 / HotFix:2025.12.18"
$Mode = 0
$Screen = 0
$Index = 0
$IsoPath = $null
$DrivePath = $null
$MainForm = $null
$ScreenMountMode = $null
$ScreenIndexMode = $null

# Check if PowerShell execution is restricted
if (-not ($(Get-ExecutionPolicy).ToString() -eq "Bypass")) {
    $msg = "Your current PowerShell Execution Policy is set to[br]$(Get-ExecutionPolicy), which prevents scripts from running.[br]Do you want to change it to Bypass?" -replace "\[br\]", "`n"
    $agree = Invoke-PopupYesOrNo -title "Change execution policy?" -message $msg
    if ($agree) {
        Set-ExecutionPolicy Bypass -Scope Process -Confirm:$false
    }
    else {
        Write-Host "Can't run the script without changing the execution policy. Exiting..."

        Write-Host ' '
        Write-Host "Press any key to exit the script..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    # Forward every bound parameter (and quote paths) so the elevated run keeps the user's options
    $newProcess.Arguments = Get-RelaunchArguments -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters;
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit 0
}

# Start the transcript and prepare the window
# One transcript per run so a failed build's evidence is never overwritten
$transcriptPath = Join-Path $ScratchDisk ("tiny11_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $transcriptPath

# Get host architecture
$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE

# Download "autounattend.xml" if file doesn't exists
if (-not (Test-Path -Path "$($PSScriptRoot)/autounattend.xml")) {
    Write-Host "Downloading autounattend.xml..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml" -OutFile "$($PSScriptRoot)\autounattend.xml"

    if (Test-Path -Path "$($PSScriptRoot)/autounattend.xml") {
        Write-Host "autounattend.xml downloaded successfully."
    }
    else {
        Write-Error "Failed to download autounattend.xml. Aborting..."

        Write-Host ' '
        Write-Host "Press any key to exit the script..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }
}

# Answer file for the image and the media: the repository template, or a generated copy that also declares the local account
$answerFileDocument = $null
if ($LocalAccountName) {
    $answerFileDocument = New-UnattendWithLocalAccount -TemplatePath "$PSScriptRoot\autounattend.xml" -AccountName $LocalAccountName
    Write-Host "Answer file will create local account '$LocalAccountName' (blank password, new one required at the next sign-in)."
}

# Get location of "oscdimg.exe" or download it from the internet
$OSCDIMG = $null
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$($hostarchitecture)\Oscdimg"
$localOSCDIMGPath = "$($PSScriptRoot)\oscdimg.exe"

if ([System.IO.Directory]::Exists($ADKDepTools)) {
    Write-Host "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$($ADKDepTools)\oscdimg.exe"
}
else {
    Write-Host "ADK folder not found. Will be using bundled oscdimg.exe."

    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Host "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe" -OutFile $localOSCDIMGPath

        if (Test-Path $localOSCDIMGPath) {
            Write-Host "`"oscdimg.exe`" downloaded successfully."
        }
        else {
            Write-Error "Failed to download oscdimg.exe. Aborting..."

            Write-Host ' '
            Write-Host "Press any key to exit the script..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            exit 1
        }
    }
    else {
        Write-Host "`"oscdimg.exe`" already exists locally."
    }

    $OSCDIMG = $localOSCDIMGPath
}

# Windows 11 24H2/25H2 images must be serviced with the Windows 11 DISM (the ADK one on Windows 10 hosts)
$dism = Resolve-DismExecutable
Write-Host "Using DISM $($dism.Version) ($($dism.Source)): $($dism.Path)"
$dismLogPath = [System.IO.Path]::ChangeExtension($transcriptPath, '.dism.log')
# DISM temp/scratch data stays on the scratch disk instead of %TEMP% on the system drive
$dismScratchPath = Join-Path $ScratchDisk 'dism-scratch'

$Host.UI.RawUI.WindowTitle = $AppTitle
Clear-Host
Write-Host "Welcome to the $($AppTitle)! Release: $($AppVersion)"

$tiny11WorkspacePath = Join-Path $ScratchDisk 'tiny11'
if (Test-Path -LiteralPath $tiny11WorkspacePath) {
    if (Test-EmptyBuilderWorkspace -Path $tiny11WorkspacePath) {
        Write-Host "Removing empty stale builder workspace: $tiny11WorkspacePath"
        try {
            Remove-Item -LiteralPath $tiny11WorkspacePath -Recurse -Force -ErrorAction Stop | Out-Null
        } catch {
            throw "Failed to remove empty stale builder workspace: $tiny11WorkspacePath. Error: $($_.Exception.Message)"
        }
    } else {
        throw "Preexisting builder workspace detected: $tiny11WorkspacePath. This directory may belong to a previous run or contain user files. Aborting before any modification."
    }
}

# Everything that creates resources (workspace, DISM scratch, ISO mount) runs inside this try,
# so the finally block also cleans up when the user closes the window and the script exits early.
try {
New-Item -ItemType Directory -Force -Path "$($ScratchDisk)\tiny11\sources" -ErrorAction Stop | Out-Null
$tiny11WorkspaceCreatedByThisRun = $true
Write-Host "Builder workspace created: $tiny11WorkspacePath (owned by this run)"

if (-not (Test-Path -LiteralPath $dismScratchPath)) {
    New-Item -ItemType Directory -Path $dismScratchPath -ErrorAction Stop | Out-Null
    $dismScratchCreatedByThisRun = $true
}
Write-Host "DISM scratch directory: $dismScratchPath. DISM log: $dismLogPath"

# Create main window
Set-DrivesList $(Find-AvaliableDrives)
$MainForm = Invoke-MainForm -title $AppTitle -version $AppVersion -icoPath $ResIconPath -splashPath $ResSplashPath
$MainForm.Show()
$MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal

# Create mounting mode screen
$ScreenMountMode = Invoke-MountMode
$MainForm.Controls.Add($ScreenMountMode)
Update-EventLoop $Screen

# User's input values - Part I
$Screen = Get-ScreenStage
$Mode = Get-ModeSelect
$IsoPath = Get-IsoPath
$DrivePath = Get-SelectedDrive

# Hide the window and erase mount mode screen
$MainForm.Controls.Remove($ScreenMountMode)
$MainForm.Visible = $false

# User has closed the window, aborting...
if ($Screen -eq 0) {
    exit 0
}

# User selected ISO file to mount
if ($Mode -eq 1) {
    Write-Host "Mounting file $($IsoPath)..."
    $DrivePath = Mount-WindowsIso $IsoPath
    Write-Host "Disk mounted at $DrivePath"
    $sourceIsoMountedByThisRun = $true
}
# User selected already mounted drive
else {
    Write-Host "Using $DrivePath as Windows setup image path..."
}

# Get list of avaliable Windows editions inside the ISO
Set-EditionsList $(Find-AllAvaliableEditions $DrivePath -DismPath $dism.Path -LogPath $dismLogPath -ScratchDir $dismScratchPath)

# Create image index screen
$ScreenIndexMode = Invoke-ImageIndexMode
$MainForm.Controls.Add($ScreenIndexMode)
$MainForm.Visible = $true
Update-EventLoop $Screen

# User's input values - Part II
$Screen = Get-ScreenStage
$Index = Get-SelectedImageIndex

# User has closed the window, aborting...
if ($Screen -ne 2) {
    exit 0
}

# Close window
$MainForm.Close()

    Write-Host "Using image index: $Index"

# Normalize an ESD source to the builder's WIM working format
$sourceInstallEsdPath = Join-Path $DrivePath 'sources\install.esd'
$sourceInstallWimPath = Join-Path $DrivePath 'sources\install.wim'
$sourceInstallImagePath = $sourceInstallWimPath
$installImagePath = Join-Path $ScratchDisk 'tiny11\sources\install.wim'
$ConvertedFromESD = Test-Path -LiteralPath $sourceInstallEsdPath
if ($ConvertedFromESD) {
    $sourceInstallImagePath = $sourceInstallEsdPath
    Write-Host 'Converting install.esd to install.wim. This may take a while...'
    Invoke-Dism -DismPath $dism.Path -Operation 'export ESD to WIM' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Export-Image', "/SourceImageFile:$sourceInstallImagePath", "/SourceIndex:$Index", "/DestinationImageFile:$installImagePath", '/Compress:max', '/CheckIntegrity')
}

Write-Host "Copying Windows image..."
$sourceEntries = @(Get-ChildItem -LiteralPath $DrivePath -Force -ErrorAction Stop)
foreach ($sourceEntry in $sourceEntries) {
    Copy-Item -LiteralPath $sourceEntry.FullName -Destination "$($ScratchDisk)\tiny11" -Recurse -Force -ErrorAction Stop | Out-Null
}
$copiedInstallImagePath = Join-Path (Split-Path -Parent $installImagePath) (Split-Path -Leaf $sourceInstallImagePath)
if (-not (Test-Path -LiteralPath $installImagePath)) {
    throw "Copied Windows setup image was not found: $installImagePath"
}
if ($ConvertedFromESD) {
    Set-ItemProperty -LiteralPath $copiedInstallImagePath -Name IsReadOnly -Value $false -ErrorAction Stop
    Remove-Item -LiteralPath $copiedInstallImagePath -Force -ErrorAction Stop
}
Write-Host "Copy complete!"
Start-Sleep -Seconds 2
Clear-Host

# If setup was converted from ESD file, then there's only 1 index avaliable
if ($ConvertedFromESD) {
    $Index = 1
}

Write-Host "Mounting Windows image. This may take a while."

$takeownOutput = & 'takeown' '/f' $installImagePath 2>&1
$takeownExitCode = $LASTEXITCODE
if ($takeownExitCode -ne 0) {
    throw "takeown failed for $installImagePath. Exit code: $takeownExitCode. Output: $takeownOutput"
}

$icaclsOutput = & 'icacls' $installImagePath "/grant" "$($adminGroup.Value):(F)" 2>&1
$icaclsExitCode = $LASTEXITCODE
if ($icaclsExitCode -ne 0) {
    throw "icacls failed for $installImagePath. Exit code: $icaclsExitCode. Output: $icaclsOutput"
}

try {
    Set-ItemProperty -LiteralPath $installImagePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    throw "Failed to make WIM file writable: $($_.Exception.Message)"
}

    $scratchDirPath = Join-Path $ScratchDisk 'scratchdir'
    if (Test-Path -LiteralPath $scratchDirPath) {
        throw "Preexisting builder scratch directory detected: $scratchDirPath. This directory may belong to a previous run or contain user files. Aborting before any modification."
    }
    New-Item -ItemType Directory -Force -Path "$($ScratchDisk)\scratchdir" -ErrorAction Stop | Out-Null
    $scratchDirCreatedByThisRun = $true
    Write-Host "Builder scratch directory created: $scratchDirPath (owned by this run)"

Invoke-Dism -DismPath $dism.Path -Operation "mount $installImagePath" -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Mount-Image', "/ImageFile:$installImagePath", "/Index:$Index", "/MountDir:$($ScratchDisk)\scratchdir")

$mountedDir = Join-Path $ScratchDisk 'scratchdir'
if (-not (Test-Path -LiteralPath (Join-Path $mountedDir 'Windows'))) {
    throw "DISM mount succeeded but offline image structure not found in $mountedDir. Aborting."
}

$installImageMountedByThisRun = $true
Write-Host "INSTALL IMAGE MOUNTED: $mountedDir (owned by this build)"

$imageIntlOutput = Invoke-Dism -DismPath $dism.Path -Operation 'get image international settings' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Get-Intl') -CaptureOutput
$imageIntl = $imageIntlOutput -join "`n"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Host "Default system UI language code: $languageCode"
}
else {
    Write-Host "Default system UI language code not found."
}

$imageInfoOutput = Invoke-Dism -DismPath $dism.Path -Operation 'get image info' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Get-WimInfo', "/WimFile:$installImagePath", "/Index:$Index") -CaptureOutput
$imageInfo = $imageInfoOutput -join "`n"
$lines = $imageInfo -split '\r?\n'

foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        # If the architecture is x64, replace it with amd64
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Host "Architecture: $architecture"
        break
    }
}

if (-not $architecture) {
    Write-Host "Architecture information not found."
}

Write-Host '--------------------------------------------------------'
Write-Host "Mounting complete! Performing removal of applications..."

$packagesOutput = Invoke-Dism -DismPath $dism.Path -Operation 'get provisioned AppX packages' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Get-ProvisionedAppxPackages') -CaptureOutput
$packages = @(ConvertFrom-ProvisionedAppxOutput $packagesOutput)

# Balanced V1 AppX removal policy (Wave 1A)
# SAFE REMOVE: consumer bloat with clear benefit and low compatibility risk
# All other targets are preserved (KEEP / OPTIONAL-DEFER / INVESTIGATE)

$packagePrefixes = 'Clipchamp.Clipchamp',
'Microsoft.BingNews',
'Microsoft.BingWeather',
'Microsoft.Copilot',
'Microsoft.Getstarted',
'Microsoft.MicrosoftOfficeHub',
'Microsoft.MicrosoftSolitaireCollection',
'Microsoft.OutlookForWindows',
'Microsoft.People',
'Microsoft.PowerAutomateDesktop',
'Microsoft.Windows.Copilot',
'Microsoft.Windows.Teams',
'Microsoft.WindowsFeedbackHub',
'MicrosoftCorporationII.MicrosoftFamily',
'MSTeams',
'MicrosoftTeams'

# Balanced V1 KEEP (mandatory) provisioned apps; the validation gate fails the build if any is missing
$requiredProvisionedPrefixes = 'Microsoft.WindowsStore',
'Microsoft.DesktopAppInstaller',
'Microsoft.WindowsTerminal',
'Microsoft.SecHealthUI'

$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}

foreach ($package in $packagesToRemove) {
    Write-Host "Removing application: $package"
    Invoke-Dism -DismPath $dism.Path -Operation "remove provisioned AppX package $package" -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Remove-ProvisionedAppxPackage', "/PackageName:$package")
}

Write-Host '--------------------------------------------------------'
Write-Host "Application removal complete. Preserving optional Windows packages..."
Start-Sleep -Seconds 1

Write-Host "Balanced V1 preserves optional Windows packages and Features on Demand."
Write-Host "No DISM /Remove-Package operation is performed in this profile."

Write-Host '--------------------------------------------------------'
Write-Output "Browser and file-ownership preservation (Balanced V1)"
Write-Host "Balanced V1 keeps Edge browser, WebView2 runtime, and OneDrive binaries."
Write-Host "Physical deletion of these components is deferred to a later profile."
Start-Sleep -Seconds 2

Write-Host '--------------------------------------------------------'
Write-Host "Loading registry..."

$offlineHivesReady = $true

$hiveDefinitions = @(
    @{ Alias = 'zCOMPONENTS'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\COMPONENTS') },
    @{ Alias = 'zDEFAULT'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\default') },
    @{ Alias = 'zNTUSER'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Users\Default\ntuser.dat') },
    @{ Alias = 'zSOFTWARE'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\SOFTWARE') },
    @{ Alias = 'zSYSTEM'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\SYSTEM') }
)

foreach ($hiveDef in $hiveDefinitions) {
    $preexistingPath = "HKLM:\$($hiveDef.Alias)"
    if (Test-Path -LiteralPath $preexistingPath) {
        throw "Preexisting offline hive alias detected: HKLM\$($hiveDef.Alias). This may belong to a stale or unrelated registry hive. Aborting before any registry mutation. Investigate manually."
    }
}

$offlineHivesReady = $true

foreach ($hiveDef in $hiveDefinitions) {
    if (-not (Test-Path -LiteralPath $hiveDef.SourcePath)) {
        throw "Offline hive file not found: $($hiveDef.SourcePath)"
    }

    $regOutput = & 'reg' 'load' "HKLM\$($hiveDef.Alias)" $hiveDef.SourcePath 2>&1
    $regExitCode = $LASTEXITCODE

    if ($regExitCode -ne 0) {
        throw "Failed to load offline hive $($hiveDef.Alias) from $($hiveDef.SourcePath). Exit code: $regExitCode. Output: $regOutput"
    }

    $hiveCheckPath = "HKLM:\$($hiveDef.Alias)"
    if (-not (Test-Path -LiteralPath $hiveCheckPath)) {
        throw "Offline hive $($hiveDef.Alias) was not created in registry after load."
    }

    Write-Host "Loaded offline hive: $($hiveDef.Alias)"
    $loadedInstallHives += $hiveDef.Alias
}

if (-not $offlineHivesReady) {
    throw "Offline registry hives could not be loaded. Aborting before any registry mutation."
}

if ($AllowUnsupportedHardware) {
    Write-Output "Bypassing system requirements (on the system image)..."
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
 } else {
    Write-Host "Hardware bypass disabled: original Windows 11 requirements preserved."
}

Write-Output "Disabling Sponsored Apps..."
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' -IgnoreMissing
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' -IgnoreMissing
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

Write-Output "Enabling Local Accounts on OOBE..."
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
Write-AnswerFile -TemplatePath "$PSScriptRoot\autounattend.xml" -Destination "$($ScratchDisk)\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Document $answerFileDocument

Write-Output "Disabling Chat icon..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

if ($BlockOneDriveSync) {
    Write-Output "Blocking OneDrive file sync by explicit option..."
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
} else {
    Write-Host "OneDrive file sync remains available on demand."
}

Write-Output "Disabling Telemetry..."
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
# Preserve dmwappushservice: disabling it may affect device management.

# Do not modify undocumented Windows Update Orchestrator completion flags.
# Provisioned consumer apps are handled by the approved removal policy.

Write-Output "Disabling Copilot..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

Write-Output "Prevents installation of Teams..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

Write-Output "Prevent installation of New Outlook..."
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

Write-Host "Preserving scheduled task definition files..."
Write-Host "Balanced V1 keeps Windows scheduled-task files intact for servicing and repairability."
Write-Host "Physical deletion of scheduled-task files is deferred to a later profile."

Write-Host "Tweaking complete!"
    Write-Host "Unmounting Registry..."

    Unload-OfflineHives -HiveAliases $loadedInstallHives -Stage 'install'
    $loadedInstallHives = @()

    Write-Host '--------------------------------------------------------'
    Write-Host "Cleaning up image..."
    Invoke-Dism -DismPath $dism.Path -Operation 'cleanup image' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Cleanup-Image', '/StartComponentCleanup')

    Write-Host "Cleanup complete."
    Write-Host ' '

    # Validation gate: a broken image is discarded by the finally block instead of being committed and shipped
    Write-Host "Validating serviced image before commit..."
    $scanHealthOutput = Invoke-Dism -DismPath $dism.Path -Operation 'scan component store health' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Cleanup-Image', '/ScanHealth') -CaptureOutput
    $provisionedAfterServicing = @(ConvertFrom-ProvisionedAppxOutput (Invoke-Dism -DismPath $dism.Path -Operation 'list provisioned AppX packages after servicing' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Get-ProvisionedAppxPackages') -CaptureOutput))
    $imageValidationFailures = @(Get-ImageValidationFailures -ProvisionedPackages $provisionedAfterServicing -RemovedPrefixes $packagePrefixes -RequiredPrefixes $requiredProvisionedPrefixes -ScanHealthOutput $scanHealthOutput -MountDir "$($ScratchDisk)\scratchdir")
    if ($imageValidationFailures.Count -gt 0) {
        throw "Serviced image validation failed; install.wim will be discarded, not committed:`n - $($imageValidationFailures -join "`n - ")"
    }
    Write-Host "Image validation passed: component store healthy, removed apps gone, protected apps and required components present."

    if ($EnableNetFx3) {
        # Runs after component cleanup: enabling NetFx3 leaves pending operations that make /StartComponentCleanup fail
        $netFx3SourcePath = Join-Path $ScratchDisk 'tiny11\sources\sxs'
        if (-not (Test-Path -LiteralPath $netFx3SourcePath)) {
            throw "-EnableNetFx3 was requested but the setup media has no sources\sxs folder: $netFx3SourcePath"
        }
        Invoke-Dism -DismPath $dism.Path -Operation 'enable .NET Framework 3.5 (NetFx3) from media sources\sxs' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Enable-Feature', '/FeatureName:NetFx3', '/All', '/LimitAccess', "/Source:$netFx3SourcePath")
        $netFx3Info = Invoke-Dism -DismPath $dism.Path -Operation 'verify NetFx3 state' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @("/Image:$($ScratchDisk)\scratchdir", '/Get-FeatureInfo', '/FeatureName:NetFx3') -CaptureOutput
        Assert-FeatureEnabled -FeatureName 'NetFx3' -FeatureInfoOutput $netFx3Info
        Write-Host ".NET Framework 3.5 enabled in the image."
    }

    Write-Host "Unmounting image..."
    Invoke-Dism -DismPath $dism.Path -Operation 'unmount install.wim (commit)' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Unmount-Image', "/MountDir:$($ScratchDisk)\scratchdir", '/Commit')

    $installImageMountedByThisRun = $false
    Write-Host "INSTALL IMAGE RELEASED: mount committed successfully."

Write-Host "Exporting image..."
Invoke-Dism -DismPath $dism.Path -Operation 'export install image to install2.wim' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Export-Image', "/SourceImageFile:$installImagePath", "/SourceIndex:$Index", "/DestinationImageFile:$($ScratchDisk)\tiny11\sources\install2.wim", '/Compress:max')
Remove-Item -LiteralPath $installImagePath -Force -ErrorAction Stop | Out-Null
Rename-Item -Path "$($ScratchDisk)\tiny11\sources\install2.wim" -NewName "install.wim" -ErrorAction Stop | Out-Null
Write-Host "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2

Write-Host '--------------------------------------------------------'
Write-Host "Mounting boot image:"
$wimFilePath = "$($ScratchDisk)\tiny11\sources\boot.wim"

$bootTakeownOutput = & 'takeown' "/f" $wimFilePath 2>&1
$bootTakeownExitCode = $LASTEXITCODE
if ($bootTakeownExitCode -ne 0) {
    throw "takeown failed for boot.wim. Exit code: $bootTakeownExitCode. Output: $bootTakeownOutput"
}

$bootIcaclsOutput = & 'icacls' $wimFilePath "/grant" "$($adminGroup.Value):(F)" 2>&1
$bootIcaclsExitCode = $LASTEXITCODE
if ($bootIcaclsExitCode -ne 0) {
    throw "icacls failed for boot.wim. Exit code: $bootIcaclsExitCode. Output: $bootIcaclsOutput"
}

Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop

Invoke-Dism -DismPath $dism.Path -Operation 'mount boot.wim index 2' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Mount-Image', "/ImageFile:$($ScratchDisk)\tiny11\sources\boot.wim", '/Index:2', "/MountDir:$($ScratchDisk)\scratchdir")

$bootMountedDir = Join-Path $ScratchDisk 'scratchdir'
if (-not (Test-Path -LiteralPath (Join-Path $bootMountedDir 'Windows'))) {
    throw "DISM mount succeeded but boot offline image structure not found in $bootMountedDir. Aborting."
}

$bootImageMountedByThisRun = $true
Write-Host "BOOT IMAGE MOUNTED: $bootMountedDir (owned by this build)"

Write-Host "Loading registry..."

$bootOfflineHivesReady = $true

$bootHiveDefinitions = @(
    @{ Alias = 'zDEFAULT'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\default') },
    @{ Alias = 'zNTUSER'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Users\Default\ntuser.dat') },
    @{ Alias = 'zSYSTEM'; SourcePath = (Join-Path $ScratchDisk 'scratchdir\Windows\System32\config\SYSTEM') }
)

foreach ($hiveDef in $bootHiveDefinitions) {
    $preexistingPath = "HKLM:\$($hiveDef.Alias)"
    if (Test-Path -LiteralPath $preexistingPath) {
        throw "Preexisting boot offline hive alias detected: HKLM\$($hiveDef.Alias). This may belong to a stale or unrelated registry hive. Aborting before any registry mutation. Investigate manually."
    }
}

$bootOfflineHivesReady = $true

foreach ($hiveDef in $bootHiveDefinitions) {
    if (-not (Test-Path -LiteralPath $hiveDef.SourcePath)) {
        throw "Boot offline hive file not found: $($hiveDef.SourcePath)"
    }

    $regOutput = & 'reg' 'load' "HKLM\$($hiveDef.Alias)" $hiveDef.SourcePath 2>&1
    $regExitCode = $LASTEXITCODE

    if ($regExitCode -ne 0) {
        throw "Failed to load boot offline hive $($hiveDef.Alias) from $($hiveDef.SourcePath). Exit code: $regExitCode. Output: $regOutput"
    }

    $hiveCheckPath = "HKLM:\$($hiveDef.Alias)"
    if (-not (Test-Path -LiteralPath $hiveCheckPath)) {
        throw "Boot offline hive $($hiveDef.Alias) was not created in registry after load."
    }

    Write-Host "Loaded boot offline hive: $($hiveDef.Alias)"
    $loadedBootHives += $hiveDef.Alias
}

if (-not $bootOfflineHivesReady) {
    throw "Boot offline registry hives could not be loaded. Aborting before any registry mutation."
}

if ($AllowUnsupportedHardware) {
    Write-Host "Bypassing system requirements (on the setup image)..."
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
 } else {
    Write-Host "Setup hardware bypass disabled."
}

Write-Host "Tweaking complete!"
    Write-Host "Unmounting Registry..."

    Unload-OfflineHives -HiveAliases $loadedBootHives -Stage 'boot'
    $loadedBootHives = @()

    Write-Host "Unmounting image..."
    Invoke-Dism -DismPath $dism.Path -Operation 'unmount boot.wim (commit)' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Unmount-Image', "/MountDir:$($ScratchDisk)\scratchdir", '/Commit')

    $bootImageMountedByThisRun = $false
    Write-Host "BOOT IMAGE RELEASED: mount committed successfully."

if ($InstallImageFormat -eq 'esd') {
    Write-Host "Exporting install.esd with recovery compression. This can take a long time..."
    Invoke-Dism -DismPath $dism.Path -Operation 'export install image to install.esd' -LogPath $dismLogPath -ScratchDir $dismScratchPath -Arguments @('/Export-Image', "/SourceImageFile:$installImagePath", '/SourceIndex:1', "/DestinationImageFile:$($ScratchDisk)\tiny11\sources\install.esd", '/Compress:recovery')
    Remove-Item -LiteralPath $installImagePath -Force -ErrorAction Stop | Out-Null
} else {
    Write-Host "Keeping install.wim (max compression, mountable and verifiable). Use -InstallImageFormat esd for a smaller ISO."
}

Write-Host '--------------------------------------------------------'
Write-Host "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Host "Copying unattended file for bypassing MS account on OOBE..."
Write-AnswerFile -TemplatePath "$PSScriptRoot\autounattend.xml" -Destination "$($ScratchDisk)\tiny11\autounattend.xml" -Document $answerFileDocument

Write-Host "Creating ISO image..."
# Must not reuse $IsoPath: PowerShell names are case-insensitive and cleanup dismounts the source ISO by that path
$outputIsoPath = "$($PSScriptRoot)\tiny11.iso"
if (Test-Path -LiteralPath $outputIsoPath) {
    Write-Host "Removing existing ISO: $outputIsoPath"
    Remove-Item -LiteralPath $outputIsoPath -Force -ErrorAction Stop | Out-Null
}
$oscdimgOutput = & "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$($ScratchDisk)\tiny11\boot\etfsboot.com#pEF,e,b$($ScratchDisk)\tiny11\efi\microsoft\boot\efisys.bin" "$($ScratchDisk)\tiny11" $outputIsoPath 2>&1
$oscdimgExitCode = $LASTEXITCODE
Assert-NativeCommandSucceeded -Operation 'oscdimg ISO creation' -Executable 'oscdimg' -ExitCode $oscdimgExitCode -Output $oscdimgOutput
if (-not (Test-Path -LiteralPath $outputIsoPath)) {
    throw "oscdimg completed but ISO output file not found: $outputIsoPath"
}
$isoLength = (Get-Item -LiteralPath $outputIsoPath).Length
if ($isoLength -le 0) {
    throw "oscdimg completed but ISO output file is empty: $outputIsoPath"
}
Write-Host "ISO created successfully: $outputIsoPath ($([math]::Round($isoLength / 1MB, 2)) MB)"

Write-Host "Writing build manifest (hashing source and output ISO)..."
$manifestPath = "$outputIsoPath.manifest.json"
$sourceIsoForManifest = if ($Mode -eq 1) { $IsoPath } else { $null }
$buildManifest = New-BuildManifest -SourceIsoPath $sourceIsoForManifest -OutputIsoPath $outputIsoPath -SourceImageInfo (ConvertFrom-DismKeyValueOutput $imageInfoOutput) -Dism $dism -RemovedAppx @($packagesToRemove) -InstallImageFormat $InstallImageFormat -NetFx3Enabled $EnableNetFx3.IsPresent -LocalAccountName $LocalAccountName -TranscriptPath $transcriptPath -DismLogPath $dismLogPath -RepositoryPath $PSScriptRoot
$buildManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
Write-Host "Build manifest written: $manifestPath"

}
catch {
    $buildException = $_
    $buildError = $_.Exception.Message
    Write-Error "BUILD FAILED: $buildError"
}
finally {
    Write-Host ''
    Write-Host '=== CLEANUP PHASE ==='

    $cleanupErrors = @()

    Unload-RegistryHivesIfOwned -HiveAliases $loadedBootHives -Stage 'boot'
    Unload-RegistryHivesIfOwned -HiveAliases $loadedInstallHives -Stage 'install'

    Unmount-ImageIfOwned -MountDir "$($ScratchDisk)\scratchdir" -ImageName 'boot.wim' -OwnershipFlag ([ref]$bootImageMountedByThisRun) -ForceDiscard
    Unmount-ImageIfOwned -MountDir "$($ScratchDisk)\scratchdir" -ImageName 'install.wim' -OwnershipFlag ([ref]$installImageMountedByThisRun) -ForceDiscard

    if ($sourceIsoMountedByThisRun -and $Mode -eq 1) {
        Dismount-IsoIfOwned -DrivePath $DrivePath -MountMode $Mode -ImagePath $IsoPath
    }

    Remove-ScratchWorkspaceIfOwned -ScratchDisk $ScratchDisk -WorkspaceName 'tiny11' -WorkspaceOwnerFlag ([ref]$tiny11WorkspaceCreatedByThisRun)
    Remove-ScratchWorkspaceIfOwned -ScratchDisk $ScratchDisk -WorkspaceName 'scratchdir' -WorkspaceOwnerFlag ([ref]$scratchDirCreatedByThisRun)
    if ($dismScratchCreatedByThisRun) {
        Remove-ScratchWorkspaceIfOwned -ScratchDisk $ScratchDisk -WorkspaceName 'dism-scratch' -WorkspaceOwnerFlag ([ref]$dismScratchCreatedByThisRun)
    }

    if ($cleanupErrors.Count -gt 0) {
        Write-Host ''
        Write-Host '=== CLEANUP WARNINGS ==='
        foreach ($err in $cleanupErrors) {
            Write-Warning $err
        }
    } else {
        Write-Host ''
        Write-Host '=== CLEANUP COMPLETE ==='
    }
}

if ($buildException) {
    throw $buildException
}

# Finishing up
if (-not $buildError) {
    $msg = "Your custom Tiny11 image was created[br]successfully! The ISO file is located[br]at $($outputIsoPath)" -replace "\[br\]", "`n"
    Write-Host ' '
    if ($cleanupErrors.Count -gt 0) {
        Write-Host "BUILD SUCCESS"
        Write-Host "CLEANUP WARNING"
    } else {
        Write-Host "Creation completed!"
    }
    Invoke-PopupInfo -title "Done!" -message $msg
}

# Stop the transcript
Stop-Transcript

if ($buildError) {
    Write-Host ''
    Write-Host "Build failed. See transcript for details: $transcriptPath"
    exit 1
}

exit 0

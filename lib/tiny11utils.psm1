#### MODULE MANIFEST FIELD ####
# The manifest (tiny11utils.psd1) is tracked in git; it is not regenerated on import.

$modulePath = $PSScriptRoot -replace '\\', '/'

#### GLOBAL VARIABLES FIELD ####

New-Variable -Name MODULE_ROOT -Value $modulePath -Scope Script -Option AllScope,Constant

#### FUNCTIONS FIELD ####

## Add/Change a key value in the registry
function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )

    $regOutput = & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Set-RegistryValue failed. Path: $path\$name. Executable: reg. Exit code: $LASTEXITCODE. Output: $regOutput"
    }
    Write-Output "Set registry value: $path\$name"
}

## Remove a key value from the registry
function Remove-RegistryValue {
    param (
        [string]$path,
        [switch]$IgnoreMissing
    )

    $regOutput = & 'reg' 'delete' $path '/f' 2>&1
    $regExitCode = $LASTEXITCODE
    $regOutputText = @($regOutput) -join "`n"
    if ($regExitCode -ne 0) {
        $missingTarget = $regOutputText -match '(?i)unable to find|not found|no ha podido encontrar|no se ha podido encontrar'
        if ($IgnoreMissing -and $missingTarget) {
            Write-Output "SKIP: Registry value/key not present: $path"
            return
        }
        throw "Remove-RegistryValue failed. Path: $path. Executable: reg. Exit code: $regExitCode. Output: $regOutputText"
    }
    Write-Output "Removed registry value: $path"
}

## This function allows PowerShell to take ownership of the Scheduled Tasks registry key from TrustedInstaller. Based on Jose Espitia's script.
function Enable-Privilege {
    param(
        [
            ValidateSet("SeAssignPrimaryTokenPrivilege", "SeAuditPrivilege", "SeBackupPrivilege",
            "SeChangeNotifyPrivilege", "SeCreateGlobalPrivilege", "SeCreatePagefilePrivilege",
            "SeCreatePermanentPrivilege", "SeCreateSymbolicLinkPrivilege", "SeCreateTokenPrivilege",
            "SeDebugPrivilege", "SeEnableDelegationPrivilege", "SeImpersonatePrivilege", "SeIncreaseBasePriorityPrivilege",
            "SeIncreaseQuotaPrivilege", "SeIncreaseWorkingSetPrivilege", "SeLoadDriverPrivilege",
            "SeLockMemoryPrivilege", "SeMachineAccountPrivilege", "SeManageVolumePrivilege",
            "SeProfileSingleProcessPrivilege", "SeRelabelPrivilege", "SeRemoteShutdownPrivilege",
            "SeRestorePrivilege", "SeSecurityPrivilege", "SeShutdownPrivilege", "SeSyncAgentPrivilege",
            "SeSystemEnvironmentPrivilege", "SeSystemProfilePrivilege", "SeSystemtimePrivilege",
            "SeTakeOwnershipPrivilege", "SeTcbPrivilege", "SeTimeZonePrivilege", "SeTrustedCredManAccessPrivilege",
            "SeUndockPrivilege", "SeUnsolicitedInputPrivilege")
        ] $Privilege,
        ## The process on which to adjust the privilege. Defaults to the current process.
        $ProcessId = $pid,
        ## Switch to disable the privilege, rather than enable it.
        [Switch] $Disable
    )

    $srcFilePath = "$($MODULE_ROOT)/AdjPriv.cs"
    $srcAdjPriv = Get-Content -Path $srcFilePath -Raw
    $processHandle = (Get-Process -id $ProcessId).Handle
    $type = Add-Type -TypeDefinition $srcAdjPriv -PassThru
    $type[0]::EnablePrivilege($processHandle, $Privilege, $Disable)
}

## Lists all avaliable file system drives in the machine
function Find-AvaliableDrives {
    $AllDrives = Get-PSDrive -PSProvider FileSystem
    return $AllDrives.Root
}

## Creates a list with the index of avaliable Windows 11 editions
function Find-AllAvaliableEditions {
    param(
        [Parameter(Mandatory=$true)]
        [string]$isoDrive,
        [Parameter(Mandatory=$true)]
        [string]$DismPath,
        [Parameter(Mandatory=$true)]
        [string]$LogPath,
        [Parameter(Mandatory=$true)]
        [string]$ScratchDir
    )

    $InstallDataPath = "$($isoDrive)sources\install.esd"

    # If install.esd doesn't exists, try install.wim
    if (-not (Test-Path $InstallDataPath)) {
        $InstallDataPath = "$($isoDrive)sources\install.wim"
    }

    # If install.wim doesn't exists either, then give up
    if (-not (Test-Path $InstallDataPath)) {
        Write-Error "Unable to find file `"install.esd`" or `"install.wim`""
        return @("No image index found")
    }

    $EditionsRawOutput = Invoke-Dism -DismPath $DismPath -Operation "list editions in $InstallDataPath" -LogPath $LogPath -ScratchDir $ScratchDir -Arguments @('/Get-WimInfo', "/WimFile:$InstallDataPath") -CaptureOutput
    $EditionsRaw = $EditionsRawOutput -join "`n"
    $EditionsArray = $EditionsRaw.Split("`n")
    $EditionsClean = @()
    $IndexID = 0

    foreach ($item in $EditionsArray) {
        if ($item.Contains("Name : ")) {
            $IndexID += 1
            $EditionsClean += $("$IndexID - " + $item -replace "Name : ", "")
        }
    }

    return $EditionsClean
}

## Mounts a ISO file image and return it's drive path
function Mount-WindowsIso {
    param(
        [Parameter(Mandatory=$true)]
        [string]$filePath
    )

    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "ISO file not found: $filePath"
    }

    try {
        $isoDisk = Mount-DiskImage -ImagePath $filePath -StorageType ISO -PassThru
    } catch {
        throw "Failed to mount ISO image: $filePath. Error: $($_.Exception.Message)"
    }

    $volumeResolutionTimeout = [TimeSpan]::FromSeconds(60)
    $volumeResolutionPollInterval = [TimeSpan]::FromMilliseconds(250)
    $volumeResolutionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $volumeResolutionError = $null
    $isoVolume = $null

    while ($volumeResolutionStopwatch.Elapsed -lt $volumeResolutionTimeout) {
        try {
            $isoDisk = Get-DiskImage -ImagePath $filePath -ErrorAction Stop
            $isoVolume = Get-Volume -DiskImage $isoDisk -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.DriveLetter) -or
                    -not [string]::IsNullOrWhiteSpace([string]$_.Path)
                } |
                Select-Object -First 1
            if ($isoVolume) {
                break
            }
        } catch {
            $volumeResolutionError = $_
        }

        Start-Sleep -Milliseconds ([int]$volumeResolutionPollInterval.TotalMilliseconds)
    }

    if (-not $isoVolume) {
        Dismount-DiskImage -ImagePath $filePath | Out-Null
        if ($volumeResolutionError) {
            throw "Mounted ISO but failed to resolve volume within 60 seconds for: $filePath. Error: $($volumeResolutionError.Exception.Message)"
        }
        throw "Mounted ISO did not expose an accessible volume path within 60 seconds: $filePath"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$isoVolume.DriveLetter)) {
        $mountedDrive = $($isoVolume.DriveLetter + ":\")
    } else {
        $mountedDrive = [string]$isoVolume.Path
    }
    $installEsdPath = Join-Path $mountedDrive 'sources\install.esd'
    $installWimPath = Join-Path $mountedDrive 'sources\install.wim'

    if (-not (Test-Path -LiteralPath $installEsdPath) -and -not (Test-Path -LiteralPath $installWimPath)) {
        Dismount-DiskImage -ImagePath $filePath | Out-Null
        throw "Mounted drive $mountedDrive does not contain a Windows setup image (install.esd or install.wim not found in sources\)."
    }

    return $mountedDrive
}

## Selects a DISM able to service Windows 11 24H2/25H2 images.
## Microsoft supports servicing Windows 11 from a Windows 10 host only with the Windows 11 (ADK) DISM.
function Resolve-DismExecutable {
    param(
        [string]$AdkDismPath = (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$($env:PROCESSOR_ARCHITECTURE)\DISM\dism.exe"),
        [string]$SystemDismPath = (Join-Path $env:SystemRoot 'System32\dism.exe'),
        [version]$MinimumVersion = '10.0.26100.0',
        [scriptblock]$GetFileVersion = {
            param($Path)
            $info = (Get-Item -LiteralPath $Path).VersionInfo
            [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        }
    )

    $candidates = @(
        @{ Source = 'Windows ADK'; Path = $AdkDismPath },
        @{ Source = 'System'; Path = $SystemDismPath }
    )
    $rejected = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) {
            $rejected += "$($candidate.Source): not found at $($candidate.Path)"
            continue
        }
        $version = & $GetFileVersion $candidate.Path
        if ($version -ge $MinimumVersion) {
            return [pscustomobject]@{ Path = $candidate.Path; Version = $version; Source = $candidate.Source }
        }
        $rejected += "$($candidate.Source): $($candidate.Path) is version $version"
    }

    throw "No DISM >= $MinimumVersion found. Servicing Windows 11 24H2/25H2 images requires the Windows 11 DISM: install the Windows ADK for Windows 11 (version 24H2 / 10.0.26100 or later). Rejected: $($rejected -join '; ')"
}

## Quotes one argument for a Windows command line (CommandLineToArgvW rules)
function ConvertTo-CommandLineArgument {
    param([string]$Argument)

    if ($Argument -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($char -eq [char]'"') {
            [void]$builder.Append([char]'\', ($backslashes * 2) + 1)
        } elseif ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
        }
        $backslashes = 0
        [void]$builder.Append($char)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', $backslashes * 2)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

## Extracts package names from `DISM /Get-ProvisionedAppxPackages` output
function ConvertFrom-ProvisionedAppxOutput {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    foreach ($line in $Output) {
        if ($line -match '^\s*PackageName\s*:\s*(\S.*?)\s*$') {
            $Matches[1]
        }
    }
}

## Checks a serviced, still-mounted image before it is committed. Returns one message per failure.
function Get-ImageValidationFailures {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProvisionedPackages = @(),
        [string[]]$RemovedPrefixes = @(),
        [string[]]$RequiredPrefixes = @(),
        [AllowEmptyCollection()]
        [string[]]$ScanHealthOutput = @(),
        [Parameter(Mandatory=$true)]
        [string]$MountDir,
        # Balanced V1 KEEP components that are files, relative to the image root
        [string[]]$RequiredPaths = @(
            'Windows\System32\Recovery\Winre.wim',
            'Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
            'Windows\System32\Dism.exe',
            'Windows\System32\sfc.exe',
            'Windows\System32\Microsoft-Edge-Webview'
        )
    )

    $failures = @()

    foreach ($package in $ProvisionedPackages) {
        if (@($RemovedPrefixes | Where-Object { $package -like "$_*" }).Count -gt 0) {
            $failures += "Removed app is still provisioned: $package"
        }
    }

    foreach ($prefix in $RequiredPrefixes) {
        if (@($ProvisionedPackages | Where-Object { $_ -like "$($prefix)_*" }).Count -eq 0) {
            $failures += "Protected app is not provisioned: $prefix"
        }
    }

    $scanText = $ScanHealthOutput -join "`n"
    if ($scanText -notmatch 'No component store corruption detected') {
        $verdict = @($ScanHealthOutput | Where-Object { $_ -match 'component store' }) | Select-Object -Last 1
        if (-not $verdict) { $verdict = '<no component store verdict in output>' }
        $failures += "DISM /ScanHealth did not report a healthy component store: $($verdict.Trim())"
    }

    foreach ($relativePath in $RequiredPaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $relativePath))) {
            $failures += "Required component missing from image: $relativePath"
        }
    }

    $failures
}

## Parses "Key : Value" lines of DISM output into an ordered dictionary (first occurrence wins)
function ConvertFrom-DismKeyValueOutput {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    $result = [ordered]@{}
    foreach ($line in $Output) {
        if ($line -match '^\s*([^:]+?)\s+:\s*(.*?)\s*$') {
            $key = $Matches[1]
            if (-not $result.Contains($key)) {
                $result[$key] = $Matches[2]
            }
        }
    }
    return $result
}

## Throws unless `DISM /Get-FeatureInfo` output reports the feature as Enabled or Enable Pending
function Assert-FeatureEnabled {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FeatureName,
        [AllowEmptyCollection()]
        [string[]]$FeatureInfoOutput
    )

    $state = (ConvertFrom-DismKeyValueOutput $FeatureInfoOutput)['State']
    if ($state -notin @('Enabled', 'Enable Pending')) {
        throw "Feature $FeatureName is not enabled in the image. Reported state: $(if ($state) { $state } else { '<none>' })"
    }
}

## Throws unless a name can be used for a new local account created by Windows Setup
function Assert-LocalAccountName {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Name
    )

    # SAM account names are limited to 20 characters; the allowlist also keeps the name safe inside a quoted command line
    if ($Name -notmatch '\A[\p{L}\p{Nd}](?:[\p{L}\p{Nd} ._-]{0,18}[\p{L}\p{Nd}_-])?\z') {
        throw "-LocalAccountName '$Name' is not a valid local account name: use 1-20 letters, digits, spaces, '.', '-' or '_', starting with a letter or digit and not ending with a space or '.'."
    }
    # Built-in accounts already exist in the image; NONE is reserved by unattend
    if (@('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'NONE') -contains $Name) {
        throw "-LocalAccountName '$Name' is reserved or already exists in Windows."
    }
}

## Returns the answer file template with a local Administrators account added to oobeSystem:
## blank password, and a first-logon command that requires a new password at the next sign-in
function New-UnattendWithLocalAccount {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TemplatePath,
        [Parameter(Mandatory=$true)]
        [string]$AccountName
    )

    Assert-LocalAccountName -Name $AccountName

    $unattendNamespace = 'urn:schemas-microsoft-com:unattend'
    $wcmNamespace = 'http://schemas.microsoft.com/WMIConfig/2002/State'
    $document = New-Object System.Xml.XmlDocument
    $document.Load((Resolve-Path -LiteralPath $TemplatePath).Path)
    $ns = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('u', $unattendNamespace)
    $shellSetup = $document.SelectSingleNode("//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
    if (-not $shellSetup) {
        throw "Answer file template $TemplatePath has no oobeSystem Microsoft-Windows-Shell-Setup component to hold the local account."
    }

    function Add-UnattendElement {
        param([System.Xml.XmlNode]$Parent, [string]$Name, [string]$Text, [switch]$ListItem)
        $element = $document.CreateElement($Name, $unattendNamespace)
        if ($Text) {
            $element.InnerText = $Text
        } elseif ($PSBoundParameters.ContainsKey('Text')) {
            # Serialized as <Value></Value>, the explicit empty value, instead of <Value />
            $element.IsEmpty = $false
        }
        if ($ListItem) {
            $action = $document.CreateAttribute('wcm', 'action', $wcmNamespace)
            $action.Value = 'add'
            [void]$element.Attributes.Append($action)
        }
        [void]$Parent.AppendChild($element)
        $element
    }

    # Group names are language-neutral: Shell-Setup maps "Administrators" to the image's localized group
    $account = Add-UnattendElement -Parent (Add-UnattendElement -Parent (Add-UnattendElement -Parent $shellSetup -Name 'UserAccounts') -Name 'LocalAccounts') -Name 'LocalAccount' -ListItem
    $password = Add-UnattendElement -Parent $account -Name 'Password'
    [void](Add-UnattendElement -Parent $password -Name 'Value' -Text '')
    [void](Add-UnattendElement -Parent $password -Name 'PlainText' -Text 'true')
    [void](Add-UnattendElement -Parent $account -Name 'Group' -Text 'Administrators')
    [void](Add-UnattendElement -Parent $account -Name 'Name' -Text $AccountName)

    # First-logon commands run elevated for administrators, so net user can expire the blank password
    $command = Add-UnattendElement -Parent (Add-UnattendElement -Parent $shellSetup -Name 'FirstLogonCommands') -Name 'SynchronousCommand' -ListItem
    [void](Add-UnattendElement -Parent $command -Name 'Order' -Text '1')
    [void](Add-UnattendElement -Parent $command -Name 'CommandLine' -Text "net user `"$AccountName`" /logonpasswordchg:yes")
    [void](Add-UnattendElement -Parent $command -Name 'Description' -Text 'Require a new password at the next sign-in')

    return ,$document
}

## Writes the answer file to a destination: the generated document when given, otherwise a byte-for-byte copy of the template
function Write-AnswerFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TemplatePath,
        [Parameter(Mandatory=$true)]
        [string]$Destination,
        [System.Xml.XmlDocument]$Document
    )

    if ($null -ne $Document) {
        # XmlWriter keeps an empty element on one line; XmlDocument.Save(path) indents whitespace into it
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.Encoding = New-Object System.Text.UTF8Encoding($true)
        $writer = [System.Xml.XmlWriter]::Create($Destination, $settings)
        try {
            $Document.Save($writer)
        } finally {
            $writer.Dispose()
        }
    } else {
        Copy-Item -LiteralPath $TemplatePath -Destination $Destination -Force -ErrorAction Stop | Out-Null
    }
}

## Discovers and validates the LCU/DotNet update packages under -UpdatesPath, returning the target LCU, its checkpoints and the optional .NET CU
function Get-UpdatePackageSet {
    param(
        [Parameter(Mandatory=$true)]
        [string]$UpdatesPath
    )

    if ($UpdatesPath -notmatch '^(?:[A-Za-z]:\\|\\\\)') {
        throw "-UpdatesPath must be an absolute path: '$UpdatesPath'."
    }

    if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) {
        throw "-UpdatesPath folder not found: $UpdatesPath"
    }

    $root = (Get-Item -LiteralPath $UpdatesPath).FullName
    if ($root.Length -gt 3) {
        $root = $root.TrimEnd('\')
    }

    $namePattern = '^windows11\.0-kb(?<kb>\d+)-x64(?:-[a-z0-9]+)*(?:_[0-9a-f]+)?\.msu$'

    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($entry.PSIsContainer -and $entry.Name -in @('LCU', 'DotNet')) {
            continue
        }
        if ($entry.Name -ieq 'SafeOS') {
            throw "Unsupported update folder '$($entry.FullName)'; SafeOS updates belong to BL-001 part 2 (WinRE)."
        }
        if ($entry.Name -ieq 'SetupDU') {
            throw "Unsupported update folder '$($entry.FullName)'; SetupDU updates belong to BL-001 part 4 (Setup media)."
        }
        throw "Unexpected entry in -UpdatesPath layout: $($entry.FullName)"
    }

    $lcuFolder = Join-Path $root 'LCU'
    $dotNetFolder = Join-Path $root 'DotNet'
    if (-not (Test-Path -LiteralPath $lcuFolder -PathType Container)) {
        throw "Required LCU folder not found: $lcuFolder"
    }

    # Reads direct .msu files after rejecting folders, non-.msu files and unknown names.
    function Get-MsuEntries {
        param([string]$FolderPath)
        $entries = @()
        foreach ($entry in @(Get-ChildItem -LiteralPath $FolderPath -Force)) {
            if ($entry.PSIsContainer) {
                throw "Nested update folders are not supported: $($entry.FullName)"
            }
            if ([System.IO.Path]::GetExtension($entry.Name) -ine '.msu') {
                throw "Unexpected non-.msu update file: $($entry.FullName)"
            }
            if ($entry.Name -notmatch $namePattern) {
                throw "Invalid update package name '$($entry.FullName)'; expected windows11.0-kb<digits>-x64[-<suffix>][_<hex>].msu."
            }
            $entries += [pscustomobject]@{ Path = $entry.FullName; Kb = [int]$Matches['kb'] }
        }
        return $entries
    }

    $lcuEntries = @(Get-MsuEntries -FolderPath $lcuFolder)
    $lcuEntries = @($lcuEntries | Sort-Object Kb)
    if ($lcuEntries.Count -eq 0) {
        throw "LCU folder contains no .msu packages: $lcuFolder"
    }

    $duplicateKbGroups = @($lcuEntries | Group-Object Kb | Where-Object { $_.Count -gt 1 })
    if ($duplicateKbGroups.Count -gt 0) {
        $duplicateKb = $duplicateKbGroups[0]
        $paths = @($duplicateKb.Group | ForEach-Object { [System.IO.Path]::GetFileName($_.Path) }) -join ', '
        throw "Ambiguous target KB$($duplicateKb.Name) in LCU: $paths"
    }

    $dotNet = $null
    if (Test-Path -LiteralPath $dotNetFolder -PathType Container) {
        $dotNetEntries = @(Get-MsuEntries -FolderPath $dotNetFolder)
        if ($dotNetEntries.Count -gt 1) {
            $paths = @($dotNetEntries | ForEach-Object { [System.IO.Path]::GetFileName($_.Path) }) -join ', '
            throw "DotNet folder must contain at most one .msu package: $dotNetFolder ($paths)"
        }
        if ($dotNetEntries.Count -eq 1) {
            $dotNet = $dotNetEntries[0]
        }
    }

    $lcu = $lcuEntries[$lcuEntries.Count - 1]
    $checkpoints = @()
    if ($lcuEntries.Count -gt 1) {
        $checkpoints = @($lcuEntries[0..($lcuEntries.Count - 2)])
    }

    return [pscustomobject]@{
        UpdatesPath = $root
        Lcu = $lcu
        Checkpoints = $checkpoints
        DotNet = $dotNet
    }
}

## Returns the git commit and dirty state of a repository, or $null when unavailable
function Get-GitRevision {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RepositoryPath
    )

    # Native stderr must not become a terminating error when git is missing or the path is not a repository
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }
    $commit = & git -C $RepositoryPath rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $commit) {
        return $null
    }
    $status = & git -C $RepositoryPath status --porcelain --untracked-files=no 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [pscustomobject]@{ Commit = ([string]$commit).Trim(); Dirty = [bool]$status }
}

## Describes one build: tool versions, source and output hashes, and what servicing changed
function New-BuildManifest {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourceIsoPath,
        [Parameter(Mandatory=$true)]
        [string]$OutputIsoPath,
        [System.Collections.IDictionary]$SourceImageInfo = @{},
        [Parameter(Mandatory=$true)]
        $Dism,
        [AllowEmptyCollection()]
        [string[]]$RemovedAppx = @(),
        [string]$InstallImageFormat,
        [bool]$NetFx3Enabled = $false,
        [string]$LocalAccountName,
        [string]$TranscriptPath,
        [string]$DismLogPath,
        [string]$RepositoryPath
    )

    $sourceIsoHash = $null
    if ($SourceIsoPath) {
        $sourceIsoHash = (Get-FileHash -LiteralPath $SourceIsoPath -Algorithm SHA256).Hash
    }
    $revision = $null
    if ($RepositoryPath) {
        $revision = Get-GitRevision -RepositoryPath $RepositoryPath
    }
    $sourceBuild = $null
    if ($SourceImageInfo['Version']) {
        $sourceBuild = $SourceImageInfo['Version']
        if ($SourceImageInfo['ServicePack Build']) {
            $sourceBuild = "$sourceBuild.$($SourceImageInfo['ServicePack Build'])"
        }
    }
    $outputItem = Get-Item -LiteralPath $OutputIsoPath

    [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        builder = [ordered]@{
            gitCommit = $(if ($revision) { $revision.Commit } else { $null })
            gitDirty = $(if ($revision) { $revision.Dirty } else { $null })
        }
        host = [ordered]@{
            os = [System.Environment]::OSVersion.VersionString
            powershell = $PSVersionTable.PSVersion.ToString()
        }
        dism = [ordered]@{
            path = $Dism.Path
            version = $Dism.Version.ToString()
            source = $Dism.Source
        }
        source = [ordered]@{
            isoPath = $(if ($SourceIsoPath) { $SourceIsoPath } else { $null })
            isoSha256 = $sourceIsoHash
            edition = $SourceImageInfo['Name']
            index = $SourceImageInfo['Index']
            architecture = $SourceImageInfo['Architecture']
            build = $sourceBuild
        }
        servicing = [ordered]@{
            removedAppx = @($RemovedAppx)
            installImageFormat = $InstallImageFormat
            netFx3Enabled = $NetFx3Enabled
            localAccount = $(if ($LocalAccountName) { $LocalAccountName } else { $null })
        }
        output = [ordered]@{
            isoPath = $OutputIsoPath
            isoSha256 = (Get-FileHash -LiteralPath $OutputIsoPath -Algorithm SHA256).Hash
            isoSizeBytes = $outputItem.Length
        }
        logs = [ordered]@{
            transcript = $TranscriptPath
            dism = $DismLogPath
        }
    }
}

## Builds the powershell.exe arguments that relaunch a script with the same bound parameters
function Get-RelaunchArguments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{}
    )

    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArgument $ScriptPath))
    foreach ($name in @($BoundParameters.Keys | Sort-Object)) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $parts += "-$name"
            }
            continue
        }
        $parts += "-$name"
        $parts += (ConvertTo-CommandLineArgument ([string]$value))
    }
    return $parts -join ' '
}

## Runs DISM with the builder's global options and fails loudly on a non-zero exit code.
## Default mode inherits the console so long operations show live progress;
## -CaptureOutput returns the output lines for queries that must be parsed.
function Invoke-Dism {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DismPath,
        [Parameter(Mandatory=$true)]
        [string]$Operation,
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments,
        [Parameter(Mandatory=$true)]
        [string]$LogPath,
        [Parameter(Mandatory=$true)]
        [string]$ScratchDir,
        [int[]]$AllowedExitCodes = @(0),
        [switch]$CaptureOutput
    )

    $fullArguments = New-Object System.Collections.Generic.List[string]
    $fullArguments.Add('/English')
    $fullArguments.Add("/LogPath:$LogPath")
    # /ScratchDir is documented for servicing (/Image:) commands; imaging commands get TEMP instead
    if (@($Arguments | Where-Object { $_ -like '/Image:*' }).Count -gt 0) {
        $fullArguments.Add("/ScratchDir:$ScratchDir")
    }
    foreach ($argument in $Arguments) {
        $fullArguments.Add($argument)
    }

    Write-Host "DISM: $Operation"
    $output = $null
    if ($CaptureOutput) {
        $previousTemp = $env:TEMP
        $previousTmp = $env:TMP
        try {
            $env:TEMP = $ScratchDir
            $env:TMP = $ScratchDir
            $output = @(& $DismPath @($fullArguments.ToArray()) 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $env:TEMP = $previousTemp
            $env:TMP = $previousTmp
        }
    } else {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $DismPath
        $startInfo.Arguments = (@($fullArguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.EnvironmentVariables['TEMP'] = $ScratchDir
        $startInfo.EnvironmentVariables['TMP'] = $ScratchDir
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        $message = "DISM $Operation failed. Executable: $DismPath. Exit code: $exitCode (0x$($exitCode.ToString('X8'))). Log: $LogPath."
        if ($null -ne $output) {
            $message += " Output: $(@($output) -join "`n")"
        }
        throw $message
    }

    if ($CaptureOutput) {
        return $output
    }
}

#### EXPORT FUNCTIONS FIELD ####
Export-ModuleMember -Function Set-RegistryValue
Export-ModuleMember -Function Remove-RegistryValue
Export-ModuleMember -Function Enable-Privilege
Export-ModuleMember -Function Find-AvaliableDrives
Export-ModuleMember -Function Find-AllAvaliableEditions
Export-ModuleMember -Function Mount-WindowsIso
Export-ModuleMember -Function Resolve-DismExecutable
Export-ModuleMember -Function Invoke-Dism
Export-ModuleMember -Function Get-RelaunchArguments
Export-ModuleMember -Function ConvertFrom-ProvisionedAppxOutput
Export-ModuleMember -Function Get-ImageValidationFailures
Export-ModuleMember -Function ConvertFrom-DismKeyValueOutput
Export-ModuleMember -Function Get-GitRevision
Export-ModuleMember -Function New-BuildManifest
Export-ModuleMember -Function Assert-FeatureEnabled
Export-ModuleMember -Function Assert-LocalAccountName
Export-ModuleMember -Function New-UnattendWithLocalAccount
Export-ModuleMember -Function Write-AnswerFile
Export-ModuleMember -Function Get-UpdatePackageSet

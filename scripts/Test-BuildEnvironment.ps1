[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath,
    [string]$ScratchPath = (Join-Path $env:TEMP 'windows-11-optimized-builder')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Preflight([string]$Message) {
    Write-Error -Message $Message
    exit 1
}

try {
    $iso = Get-Item -LiteralPath $IsoPath
    if ($iso.Extension -ine '.iso') { Stop-Preflight 'Source must be an .iso file.' }
    if ($iso.Length -lt 1GB) { Stop-Preflight 'Source ISO is unexpectedly small; verify original Microsoft media.' }

    $dismCandidates = @(
        (Join-Path $env:windir 'System32\dism.exe'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe')
    )
    $selectedDism = $dismCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $selectedDism) { Stop-Preflight 'DISM not found. Install Windows ADK Deployment Tools or use a supported Windows host.' }

    $null = & $selectedDism /English /? 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Preflight "DISM preflight failed: $selectedDism" }

    $fullScratch = [IO.Path]::GetFullPath($ScratchPath)
    $root = [IO.Path]::GetPathRoot($fullScratch)
    $driveInfo = [IO.DriveInfo]::new($root)
    $freeGB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
    if ($driveInfo.AvailableFreeSpace -lt 25GB) { Stop-Preflight "Insufficient free space on $root ($freeGB GB); 25 GB minimum." }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) { Stop-Preflight 'Run PowerShell as Administrator before image servicing.' }

    [pscustomobject]@{
        Status = 'PREFLIGHT_ONLY'
        SourceIso = $iso.FullName
        SourceSizeGB = [math]::Round($iso.Length / 1GB, 2)
        ScratchPath = $fullScratch
        ScratchDrive = $root
        FreeSpaceGB = $freeGB
        DismPath = $selectedDism
        IsAdministrator = $isAdmin
        ChangesMade = $false
    } | Format-List
    Write-Host 'Preflight passed. No image has been mounted or modified.'
}
catch {
    Stop-Preflight $_.Exception.Message
}

<#
.SYNOPSIS
    BL-001 part 1 update servicing tests.
.DESCRIPTION
    Pure unit tests for update package discovery, DISM /Get-Packages parsing
    and servicing diagnostics, plus static (AST) checks of how tiny11maker.ps1
    services install.wim. They never run DISM against an image: real servicing
    is proven only by the real WIM build and VM validation gates.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }
# Runs one test; an unexpected error (for example a function that does not exist yet) fails only that test
function Invoke-Case { param([string]$Name, [scriptblock]$Body) Write-Host "=== $Name ==="; try { & $Body } catch { Fail $Name "unexpected error: $($_.Exception.Message)" } }
# Returns the message of the error a script block throws, or $null when it does not throw
function Get-ThrownMessage { param([scriptblock]$Body) try { & $Body | Out-Null; return $null } catch { return $_.Exception.Message } }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$commands = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "update packages test $(New-Guid)"
New-Item -ItemType Directory -Path $sandbox | Out-Null

# Creates <sandbox>\<Name> with relative entries: a trailing '\' makes a folder, anything else a file containing 'abc'
function New-Layout {
    param([string]$Name, [string[]]$Entries)
    $root = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach ($entry in $Entries) {
        $path = Join-Path $root $entry
        if ($entry.EndsWith('\')) { New-Item -ItemType Directory -Path $path -Force | Out-Null; continue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, 'abc')
    }
    $root
}

try {
    Invoke-Case 'U1: valid layout selects the highest KB as target, checkpoints ascending' {
        $root = New-Layout 'valid' @(
            'LCU\windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu',
            'LCU\windows11.0-kb5129195-x64_d4ad0ca69de9a02bc356757581e0e0d6960c9f93.msu',
            'LCU\windows11.0-kb5065426-x64_0a1b2c.msu')
        $set = Get-UpdatePackageSet -UpdatesPath $root
        $checkpoints = @($set.Checkpoints)
        $checks = @(
            ($set.UpdatesPath -eq $root),
            ($set.Lcu.Kb -eq 5129195),
            ($set.Lcu.Path -eq (Join-Path $root 'LCU\windows11.0-kb5129195-x64_d4ad0ca69de9a02bc356757581e0e0d6960c9f93.msu')),
            ($checkpoints.Count -eq 2),
            ($checkpoints[0].Kb -eq 5043080),
            ($checkpoints[1].Kb -eq 5065426),
            ($null -eq $set.DotNet)
        )
        if ($checks -notcontains $false) { Pass 'U1' } else { Fail 'U1' "checks=$($checks -join ',') set=$($set | ConvertTo-Json -Compress -Depth 4)" }
    }

    Invoke-Case 'U2: optional DotNet accepts the -ndp481 name; an empty DotNet folder means none' {
        $withDotNet = Get-UpdatePackageSet -UpdatesPath (New-Layout 'dotnet' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'DotNet\windows11.0-kb5126052-x64-ndp481_5d2c.msu'))
        $emptyDotNet = Get-UpdatePackageSet -UpdatesPath (New-Layout 'dotnet empty' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'DotNet\'))
        $single = @($withDotNet.Checkpoints).Count -eq 0
        if ($withDotNet.DotNet.Kb -eq 5126052 -and $withDotNet.DotNet.Path -like '*\DotNet\windows11.0-kb5126052-x64-ndp481_5d2c.msu' -and $null -eq $emptyDotNet.DotNet -and $single) { Pass 'U2' } else { Fail 'U2' "dotnet=$($withDotNet.DotNet | ConvertTo-Json -Compress) empty=$($emptyDotNet.DotNet) single=$single" }
    }

    Invoke-Case 'U3: names are matched case-insensitively' {
        $set = Get-UpdatePackageSet -UpdatesPath (New-Layout 'case' @('LCU\Windows11.0-KB5129195-X64_ABCDEF.MSU'))
        if ($set.Lcu.Kb -eq 5129195) { Pass 'U3' } else { Fail 'U3' "kb=$($set.Lcu.Kb)" }
    }

    Invoke-Case 'U4: missing folder, a file, and a relative path are rejected' {
        $missing = Join-Path $sandbox 'does not exist'
        $filePath = Join-Path $sandbox 'a file.txt'; [System.IO.File]::WriteAllText($filePath, 'x')
        $mMissing = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $missing }
        $mFile = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $filePath }
        $mRelative = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath 'updates' }
        if ($mMissing -match [regex]::Escape($missing) -and $mFile -match [regex]::Escape($filePath) -and $mRelative -match 'absolute' -and $mRelative -match 'updates') { Pass 'U4' } else { Fail 'U4' "missing=[$mMissing] file=[$mFile] relative=[$mRelative]" }
    }

    Invoke-Case 'U5: LCU folder missing or without .msu is rejected' {
        $noLcu = New-Layout 'no lcu' @('DotNet\windows11.0-kb5126052-x64-ndp481_aa.msu')
        $emptyLcu = New-Layout 'empty lcu' @('LCU\')
        $mNo = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $noLcu }
        $mEmpty = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $emptyLcu }
        if ($mNo -match [regex]::Escape((Join-Path $noLcu 'LCU')) -and $mEmpty -match [regex]::Escape((Join-Path $emptyLcu 'LCU')) -and $mEmpty -match '\.msu') { Pass 'U5' } else { Fail 'U5' "no=[$mNo] empty=[$mEmpty]" }
    }

    Invoke-Case 'U6: non-.msu files (Explorer desktop.ini included) are rejected by name' {
        $lcuIni = New-Layout 'desktop ini' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'LCU\desktop.ini')
        $dotNetTxt = New-Layout 'dotnet txt' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'DotNet\readme.txt')
        $mIni = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $lcuIni }
        $mTxt = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $dotNetTxt }
        if ($mIni -match [regex]::Escape((Join-Path $lcuIni 'LCU\desktop.ini')) -and $mTxt -match [regex]::Escape((Join-Path $dotNetTxt 'DotNet\readme.txt'))) { Pass 'U6' } else { Fail 'U6' "ini=[$mIni] txt=[$mTxt]" }
    }

    Invoke-Case 'U7: names outside the Catalog pattern are rejected by name' {
        $badNames = @('windows11.0-kb5129195-arm64_ab.msu', 'windows11.0-kb5129195-x86_ab.msu', 'windows10.0-kb5129195-x64_ab.msu', 'windows11.0-x64_ab.msu', 'windows11.0-kb5129195-x64_ab (1).msu')
        $notRejected = @()
        $i = 0
        foreach ($name in $badNames) {
            $i++
            $root = New-Layout "bad name $i" @("LCU\$name")
            $message = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $root }
            if (-not ($message -match [regex]::Escape((Join-Path $root "LCU\$name")))) { $notRejected += "$name => [$message]" }
        }
        if ($notRejected.Count -eq 0) { Pass 'U7' } else { Fail 'U7' ($notRejected -join '; ') }
    }

    Invoke-Case 'U8: more than one .msu in DotNet is rejected' {
        $root = New-Layout 'two dotnet' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'DotNet\windows11.0-kb5126052-x64-ndp481_aa.msu', 'DotNet\windows11.0-kb5126053-x64-ndp481_bb.msu')
        $message = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $root }
        if ($message -match [regex]::Escape((Join-Path $root 'DotNet')) -and $message -match 'kb5126052' -and $message -match 'kb5126053') { Pass 'U8' } else { Fail 'U8' "message=[$message]" }
    }

    Invoke-Case 'U9: unknown entries are rejected, naming the BL-001 part that would own them' {
        $safeOs = New-Layout 'safeos' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'SafeOS\windows11.0-kb5121002-x64_aa.cab')
        $setupDu = New-Layout 'setupdu' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'SetupDU\')
        $stray = New-Layout 'stray' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'notes.txt')
        $mSafe = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $safeOs }
        $mSetup = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $setupDu }
        $mStray = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $stray }
        if ($mSafe -match 'SafeOS' -and $mSafe -match 'part 2' -and $mSetup -match 'SetupDU' -and $mSetup -match 'part 4' -and $mStray -match [regex]::Escape((Join-Path $stray 'notes.txt'))) { Pass 'U9' } else { Fail 'U9' "safe=[$mSafe] setup=[$mSetup] stray=[$mStray]" }
    }

    Invoke-Case 'U10: subfolders inside LCU or DotNet are rejected' {
        $lcuSub = New-Layout 'lcu sub' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'LCU\old\')
        $dotNetSub = New-Layout 'dotnet sub' @('LCU\windows11.0-kb5129195-x64_aa.msu', 'DotNet\old\')
        $mLcu = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $lcuSub }
        $mDotNet = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $dotNetSub }
        if ($mLcu -match [regex]::Escape((Join-Path $lcuSub 'LCU\old')) -and $mDotNet -match [regex]::Escape((Join-Path $dotNetSub 'DotNet\old'))) { Pass 'U10' } else { Fail 'U10' "lcu=[$mLcu] dotnet=[$mDotNet]" }
    }

    Invoke-Case 'U11: duplicate KB numbers in LCU are rejected as an ambiguous target' {
        $root = New-Layout 'duplicate kb' @('LCU\windows11.0-kb5129195-x64_aaaa.msu', 'LCU\windows11.0-kb5129195-x64_bbbb.msu')
        $message = Get-ThrownMessage { Get-UpdatePackageSet -UpdatesPath $root }
        if ($message -match 'KB5129195' -and $message -match 'windows11\.0-kb5129195-x64_aaaa\.msu' -and $message -match 'windows11\.0-kb5129195-x64_bbbb\.msu') { Pass 'U11' } else { Fail 'U11' "message=[$message]" }
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

Write-Host ""
Write-Host "==============================="
Write-Host "Tests passed: $passCount"
Write-Host "Tests failed: $failCount"
Write-Host "==============================="
if ($failCount -gt 0) { exit 1 }
exit 0

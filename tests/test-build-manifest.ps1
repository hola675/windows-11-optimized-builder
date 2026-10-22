<#
.SYNOPSIS
    Build manifest tests.
.DESCRIPTION
    Exercises ConvertFrom-DismKeyValueOutput, Get-GitRevision and
    New-BuildManifest from lib\tiny11utils.psm1, and checks the builder writes
    the manifest next to the output ISO.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "manifest test $(New-Guid)"
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    Write-Host "=== TEST M1: DISM key/value output is parsed (first occurrence wins) ==="
    $wimInfoFixture = @(
        'Deployment Image Servicing and Management tool'
        'Version: 10.0.26100.2454'
        ''
        'Details for image : D:\tiny11\sources\install.wim'
        ''
        'Index : 6'
        'Name : Windows 11 Pro'
        'Description : Windows 11 Pro'
        'Size : 20.123.456.789 bytes'
        'Architecture : x64'
        'Version : 10.0.26200'
        'ServicePack Build : 9457'
        'Languages :'
        '        es-ES (Default)'
        'The operation completed successfully.'
    )
    $parsed = ConvertFrom-DismKeyValueOutput $wimInfoFixture
    if ($parsed['Name'] -eq 'Windows 11 Pro' -and $parsed['Index'] -eq '6' -and $parsed['Architecture'] -eq 'x64' -and $parsed['Version'] -eq '10.0.26200' -and $parsed['ServicePack Build'] -eq '9457') {
        Pass "TEST M1"
    } else {
        Fail "TEST M1" "parsed=$($parsed | ConvertTo-Json -Compress)"
    }

    Write-Host "=== TEST M2: Git revision of this repository; null outside a repository ==="
    $revision = Get-GitRevision -RepositoryPath $repoRoot
    $expectedCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    $outside = Get-GitRevision -RepositoryPath $sandbox
    if ($revision.Commit -eq $expectedCommit -and $revision.Dirty -is [bool] -and $null -eq $outside) { Pass "TEST M2" } else { Fail "TEST M2" "revision=$($revision | ConvertTo-Json -Compress) outside=$outside" }

    Write-Host "=== TEST M3: Manifest hashes files and records facts ==="
    $sourceIso = Join-Path $sandbox 'source image.iso'
    $outputIso = Join-Path $sandbox 'tiny11.iso'
    [System.IO.File]::WriteAllBytes($sourceIso, [System.Text.Encoding]::ASCII.GetBytes('abc'))
    [System.IO.File]::WriteAllBytes($outputIso, [System.Text.Encoding]::ASCII.GetBytes('abc'))
    $abcSha256 = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
    $manifest = New-BuildManifest -SourceIsoPath $sourceIso -OutputIsoPath $outputIso -SourceImageInfo $parsed `
        -Dism ([pscustomobject]@{ Path = 'C:\adk\dism.exe'; Version = [version]'10.0.26100.2454'; Source = 'Windows ADK' }) `
        -RemovedAppx @('Clipchamp.Clipchamp_4.4.10720.0_neutral_~_yxz26nhyzhsrt') -InstallImageFormat 'wim' -NetFx3Enabled $true `
        -TranscriptPath 'D:\x\tiny11_1.log' -DismLogPath 'D:\x\tiny11_1.dism.log' -RepositoryPath $repoRoot
    $json = $manifest | ConvertTo-Json -Depth 6
    $roundTrip = $json | ConvertFrom-Json
    # Each comparison is parenthesised: the comma operator binds tighter than -eq
    $checks = @(
        ($roundTrip.schemaVersion -eq 1),
        ($roundTrip.source.isoSha256 -eq $abcSha256),
        ($roundTrip.output.isoSha256 -eq $abcSha256),
        ($roundTrip.output.isoSizeBytes -eq 3),
        ($roundTrip.source.edition -eq 'Windows 11 Pro'),
        ($roundTrip.source.build -eq '10.0.26200.9457'),
        ($roundTrip.dism.version -eq '10.0.26100.2454'),
        ($roundTrip.servicing.removedAppx[0] -like 'Clipchamp.Clipchamp_*'),
        ($roundTrip.servicing.installImageFormat -eq 'wim'),
        ($roundTrip.servicing.netFx3Enabled -eq $true),
        ($roundTrip.builder.gitCommit -eq $expectedCommit),
        ($roundTrip.logs.dism -eq 'D:\x\tiny11_1.dism.log')
    )
    if ($checks -notcontains $false) { Pass "TEST M3" } else { Fail "TEST M3" "checks=$($checks -join ',') json=$json" }

    Write-Host "=== TEST M4: Mounted-drive source (no ISO file) records null hash ==="
    $manifest = New-BuildManifest -SourceIsoPath $null -OutputIsoPath $outputIso -SourceImageInfo $parsed -Dism ([pscustomobject]@{ Path = 'x'; Version = [version]'10.0.26100.1'; Source = 'System' }) -RemovedAppx @() -InstallImageFormat 'esd' -TranscriptPath 't' -DismLogPath 'd' -RepositoryPath $sandbox
    $roundTrip = ($manifest | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    if ($null -eq $roundTrip.source.isoSha256 -and $null -eq $roundTrip.builder.gitCommit -and $roundTrip.output.isoSha256 -eq $abcSha256) { Pass "TEST M4" } else { Fail "TEST M4" "json=$($roundTrip | ConvertTo-Json -Compress -Depth 6)" }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

# ---------------------------------------------------------------------------
# TEST M5 — Builder writes the manifest next to the ISO after creating it
# ---------------------------------------------------------------------------
Write-Host "=== TEST M5: Builder writes <iso>.manifest.json after oscdimg ==="
$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$commands = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
$oscdimgCall = $commands | Where-Object { $_.CommandElements[0].Extent.Text -match 'OSCDIMG' } | Select-Object -First 1
$manifestCall = $commands | Where-Object { $_.GetCommandName() -eq 'New-BuildManifest' } | Select-Object -First 1
$writesNextToIso = $builderAst.Extent.Text -match '\$manifestPath\s*=\s*"\$outputIsoPath\.manifest\.json"'
if ($oscdimgCall -and $manifestCall -and $writesNextToIso -and $manifestCall.Extent.StartOffset -gt $oscdimgCall.Extent.StartOffset) { Pass "TEST M5" } else { Fail "TEST M5" "oscdimg=$([bool]$oscdimgCall) manifest=$([bool]$manifestCall) path=$writesNextToIso" }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==============================="
Write-Host "Tests passed: $passCount"
Write-Host "Tests failed: $failCount"
Write-Host "==============================="
if ($failCount -gt 0) { exit 1 }
exit 0

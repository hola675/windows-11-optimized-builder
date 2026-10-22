<#
.SYNOPSIS
    Serviced image validation gate tests.
.DESCRIPTION
    Exercises ConvertFrom-ProvisionedAppxOutput and Get-ImageValidationFailures
    from lib\tiny11utils.psm1 with DISM output fixtures and a fake mounted image,
    and checks the builder runs the gate before committing install.wim.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

# Fixture shaped like `DISM /English /Image:<dir> /Get-ProvisionedAppxPackages`
$provisionedFixture = @(
    'Deployment Image Servicing and Management tool'
    'Version: 10.0.26100.2454'
    ''
    'Image Version: 10.0.26200.9457'
    ''
    'DisplayName : Microsoft.WindowsStore'
    'Version : 22509.1401.4.0'
    'Architecture : neutral'
    'ResourceId : ~'
    'PackageName : Microsoft.WindowsStore_22509.1401.4.0_neutral_~_8wekyb3d8bbwe'
    'Regions : '
    ''
    'DisplayName : Microsoft.DesktopAppInstaller'
    'PackageName : Microsoft.DesktopAppInstaller_1.26.430.0_neutral_~_8wekyb3d8bbwe'
    ''
    'DisplayName : Microsoft.WindowsTerminal'
    'PackageName : Microsoft.WindowsTerminal_3001.22.11141.0_neutral_~_8wekyb3d8bbwe'
    ''
    'DisplayName : Microsoft.SecHealthUI'
    'PackageName : Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe'
    ''
    'The operation completed successfully.'
)
$healthyScan = @('Image Version: 10.0.26200.9457', '[==========================100.0%==========================] No component store corruption detected.', 'The operation completed successfully.')
$repairableScan = @('Image Version: 10.0.26200.9457', '[==========================100.0%==========================] The component store is repairable.', 'The operation completed successfully.')
$removedPrefixes = @('Clipchamp.Clipchamp', 'Microsoft.BingNews')
$requiredPrefixes = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsTerminal', 'Microsoft.SecHealthUI')

$mountDir = Join-Path ([System.IO.Path]::GetTempPath()) "validation mount $(New-Guid)"
$requiredFiles = @(
    'Windows\System32\Recovery\Winre.wim',
    'Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    'Windows\System32\Dism.exe',
    'Windows\System32\sfc.exe',
    'Windows\System32\Microsoft-Edge-Webview\msedgewebview2.exe'
)
foreach ($file in $requiredFiles) {
    $path = Join-Path $mountDir $file
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    Set-Content -LiteralPath $path -Value ''
}

function Invoke-Gate([string[]]$Provisioned = $provisionedFixture, [string[]]$Scan = $healthyScan) {
    Get-ImageValidationFailures -ProvisionedPackages (ConvertFrom-ProvisionedAppxOutput $Provisioned) -RemovedPrefixes $removedPrefixes -RequiredPrefixes $requiredPrefixes -ScanHealthOutput $Scan -MountDir $mountDir
}

try {
    Write-Host "=== TEST V0: Provisioned AppX output is parsed to package names ==="
    $parsed = @(ConvertFrom-ProvisionedAppxOutput $provisionedFixture)
    $expectedNames = @(
        'Microsoft.WindowsStore_22509.1401.4.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.DesktopAppInstaller_1.26.430.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.WindowsTerminal_3001.22.11141.0_neutral_~_8wekyb3d8bbwe',
        'Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe'
    )
    if (($parsed -join '|') -eq ($expectedNames -join '|')) { Pass "TEST V0" } else { Fail "TEST V0" "parsed=$($parsed -join '|')" }

    Write-Host "=== TEST V1: Healthy image passes ==="
    $failures = @(Invoke-Gate)
    if ($failures.Count -eq 0) { Pass "TEST V1" } else { Fail "TEST V1" "failures=$($failures -join '; ')" }

    Write-Host "=== TEST V2: A package that should be removed is still provisioned ==="
    $withLeftover = $provisionedFixture + @('', 'DisplayName : Clipchamp.Clipchamp', 'PackageName : Clipchamp.Clipchamp_4.4.10720.0_neutral_~_yxz26nhyzhsrt')
    $failures = @(Invoke-Gate -Provisioned $withLeftover)
    if ($failures.Count -eq 1 -and $failures[0] -match 'Clipchamp\.Clipchamp_4\.4\.10720\.0') { Pass "TEST V2" } else { Fail "TEST V2" "failures=$($failures -join '; ')" }

    Write-Host "=== TEST V3: A protected package is missing ==="
    $withoutTerminal = $provisionedFixture | Where-Object { $_ -notmatch 'WindowsTerminal' }
    $failures = @(Invoke-Gate -Provisioned $withoutTerminal)
    if ($failures.Count -eq 1 -and $failures[0] -match 'Microsoft\.WindowsTerminal') { Pass "TEST V3" } else { Fail "TEST V3" "failures=$($failures -join '; ')" }

    Write-Host "=== TEST V4: Component store not reported healthy ==="
    $failures = @(Invoke-Gate -Scan $repairableScan)
    if ($failures.Count -eq 1 -and $failures[0] -match 'ScanHealth' -and $failures[0] -match 'repairable') { Pass "TEST V4" } else { Fail "TEST V4" "failures=$($failures -join '; ')" }

    Write-Host "=== TEST V5: Missing WinRE and WebView2 are both reported ==="
    Remove-Item -LiteralPath (Join-Path $mountDir 'Windows\System32\Recovery\Winre.wim')
    Remove-Item -LiteralPath (Join-Path $mountDir 'Windows\System32\Microsoft-Edge-Webview') -Recurse
    $failures = @(Invoke-Gate)
    $mentionsWinre = @($failures | Where-Object { $_ -match 'Winre\.wim' }).Count -eq 1
    $mentionsWebView = @($failures | Where-Object { $_ -match 'Microsoft-Edge-Webview' }).Count -eq 1
    if ($failures.Count -eq 2 -and $mentionsWinre -and $mentionsWebView) { Pass "TEST V5" } else { Fail "TEST V5" "failures=$($failures -join '; ')" }
} finally {
    Remove-Item -LiteralPath $mountDir -Recurse -Force
}

# ---------------------------------------------------------------------------
# TEST V6 — Builder runs ScanHealth and the gate before committing install.wim
# ---------------------------------------------------------------------------
Write-Host "=== TEST V6: Gate runs before install.wim commit and stops the build ==="
$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$commands = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
$scanCall = $commands | Where-Object { $_.GetCommandName() -eq 'Invoke-Dism' -and $_.Extent.Text -match '/ScanHealth' } | Select-Object -First 1
$gateCall = $commands | Where-Object { $_.GetCommandName() -eq 'Get-ImageValidationFailures' } | Select-Object -First 1
$installCommit = $commands | Where-Object { $_.GetCommandName() -eq 'Invoke-Dism' -and $_.Extent.Text -match "unmount install\.wim \(commit\)" } | Select-Object -First 1
$gateThrows = $builderAst.Extent.Text -match 'if \(\$imageValidationFailures\.Count -gt 0\)\s*\{\s*throw'
if ($scanCall -and $gateCall -and $installCommit -and $gateThrows -and
    $scanCall.Extent.StartOffset -lt $gateCall.Extent.StartOffset -and $gateCall.Extent.StartOffset -lt $installCommit.Extent.StartOffset) {
    Pass "TEST V6"
} else {
    Fail "TEST V6" "scan=$([bool]$scanCall) gate=$([bool]$gateCall) commit=$([bool]$installCommit) throws=$gateThrows"
}

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

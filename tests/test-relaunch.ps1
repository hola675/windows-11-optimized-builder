<#
.SYNOPSIS
    Elevation relaunch argument tests.
.DESCRIPTION
    The builder relaunches itself elevated when started without admin
    rights. These tests check that the relaunch command line preserves the
    script path and every bound parameter, including paths with spaces, by
    round-tripping it through a real powershell.exe process (no elevation).
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "relaunch test $(New-Guid)"
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    $probeScript = Join-Path $sandbox 'probe script.ps1'
    $probeOutput = Join-Path $sandbox 'bound.json'
    Set-Content -LiteralPath $probeScript -Value @(
        'param([string]$ScratchDisk, [string]$InstallImageFormat, [switch]$EnableNetFx3)'
        '$result = @{ ScratchDisk = $ScratchDisk; InstallImageFormat = $InstallImageFormat; EnableNetFx3 = [bool]$EnableNetFx3; Count = $PSBoundParameters.Count }'
        '$result | ConvertTo-Json | Set-Content -LiteralPath $env:PROBE_OUTPUT'
    )

    function Invoke-Probe([string]$Arguments) {
        if (Test-Path -LiteralPath $probeOutput) { Remove-Item -LiteralPath $probeOutput }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.EnvironmentVariables['PROBE_OUTPUT'] = $probeOutput
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "probe exited with $($process.ExitCode)" }
        return Get-Content -LiteralPath $probeOutput -Raw | ConvertFrom-Json
    }

    Write-Host "=== TEST L1: Script path and string parameters with spaces survive ==="
    $bound = @{ ScratchDisk = 'D:\Build Area\scratch dir\'; InstallImageFormat = 'esd' }
    $received = Invoke-Probe (Get-RelaunchArguments -ScriptPath $probeScript -BoundParameters $bound)
    if ($received.ScratchDisk -eq 'D:\Build Area\scratch dir\' -and $received.InstallImageFormat -eq 'esd' -and $received.Count -eq 2) { Pass "TEST L1" } else { Fail "TEST L1" "received=$($received | ConvertTo-Json -Compress)" }

    Write-Host "=== TEST L2: Present switch is forwarded, absent switch is not ==="
    $received = Invoke-Probe (Get-RelaunchArguments -ScriptPath $probeScript -BoundParameters @{ EnableNetFx3 = [switch]$true })
    $receivedOff = Invoke-Probe (Get-RelaunchArguments -ScriptPath $probeScript -BoundParameters @{ EnableNetFx3 = [switch]$false })
    if ($received.EnableNetFx3 -eq $true -and $received.Count -eq 1 -and $receivedOff.EnableNetFx3 -eq $false -and $receivedOff.Count -eq 0) { Pass "TEST L2" } else { Fail "TEST L2" "on=$($received | ConvertTo-Json -Compress) off=$($receivedOff | ConvertTo-Json -Compress)" }

    Write-Host "=== TEST L3: No parameters relaunches the script alone ==="
    $received = Invoke-Probe (Get-RelaunchArguments -ScriptPath $probeScript -BoundParameters @{})
    if ($received.Count -eq 0) { Pass "TEST L3" } else { Fail "TEST L3" "received=$($received | ConvertTo-Json -Compress)" }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

# ---------------------------------------------------------------------------
# TEST L4 — The builder's elevation path forwards its bound parameters
# ---------------------------------------------------------------------------
Write-Host "=== TEST L4: Builder relaunch uses Get-RelaunchArguments with its bound parameters ==="
$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$relaunchCalls = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-RelaunchArguments' }, $true))
$forwardsBound = @($relaunchCalls | Where-Object { $_.Extent.Text -match '\$PSBoundParameters' -and $_.Extent.Text -match '\$PSCommandPath' })
if ($relaunchCalls.Count -eq 1 -and $forwardsBound.Count -eq 1) { Pass "TEST L4" } else { Fail "TEST L4" "calls=$($relaunchCalls.Count) forwarding=$($forwardsBound.Count)" }

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

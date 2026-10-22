<#
.SYNOPSIS
    Optional .NET Framework 3.5 (NetFx3) enablement tests.
.DESCRIPTION
    NetFx3 is opt-in (-EnableNetFx3). It is enabled offline from the media's own
    sources\sxs (/LimitAccess) after component cleanup, because enabling it
    leaves pending operations that make /StartComponentCleanup fail, and its
    resulting state is verified.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)

# ---------------------------------------------------------------------------
# TEST N1 — NetFx3 is off unless -EnableNetFx3 is passed
# ---------------------------------------------------------------------------
Write-Host "=== TEST N1: -EnableNetFx3 defaults to off ==="
$probe = [scriptblock]::Create("$($builderAst.ParamBlock.Extent.Text)`n[bool]`$EnableNetFx3")
$off = & $probe
$on = & $probe -EnableNetFx3
if ($off -eq $false -and $on -eq $true) { Pass "TEST N1" } else { Fail "TEST N1" "default=$off switch=$on" }

# ---------------------------------------------------------------------------
# TEST N2 — Feature state verification accepts only Enabled / Enable Pending
# ---------------------------------------------------------------------------
Write-Host "=== TEST N2: Assert-FeatureEnabled checks the reported state ==="
$pending = @('Feature Name : NetFx3', 'Display Name : .NET Framework 3.5 (includes .NET 2.0 and 3.0)', 'Restart Required : Possible', 'State : Enable Pending', 'The operation completed successfully.')
$enabled = @('Feature Name : NetFx3', 'State : Enabled')
$removed = @('Feature Name : NetFx3', 'State : Disabled with Payload Removed')
$acceptedPending = $true; try { Assert-FeatureEnabled -FeatureName 'NetFx3' -FeatureInfoOutput $pending } catch { $acceptedPending = $false }
$acceptedEnabled = $true; try { Assert-FeatureEnabled -FeatureName 'NetFx3' -FeatureInfoOutput $enabled } catch { $acceptedEnabled = $false }
$removedError = $null; try { Assert-FeatureEnabled -FeatureName 'NetFx3' -FeatureInfoOutput $removed } catch { $removedError = $_.Exception.Message }
if ($acceptedPending -and $acceptedEnabled -and $removedError -match 'NetFx3' -and $removedError -match 'Disabled with Payload Removed') { Pass "TEST N2" } else { Fail "TEST N2" "pending=$acceptedPending enabled=$acceptedEnabled removed-error=$removedError" }

# ---------------------------------------------------------------------------
# TEST N3 — Builder enables NetFx3 only when asked, from sources\sxs, after cleanup, before commit
# ---------------------------------------------------------------------------
Write-Host "=== TEST N3: NetFx3 step is guarded, offline-sourced and correctly ordered ==="
$commands = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
$enableCall = $commands | Where-Object { $_.GetCommandName() -eq 'Invoke-Dism' -and $_.Extent.Text -match '/Enable-Feature' -and $_.Extent.Text -match 'NetFx3' } | Select-Object -First 1
$cleanupCall = $commands | Where-Object { $_.GetCommandName() -eq 'Invoke-Dism' -and $_.Extent.Text -match '/StartComponentCleanup' } | Select-Object -First 1
$installCommit = $commands | Where-Object { $_.GetCommandName() -eq 'Invoke-Dism' -and $_.Extent.Text -match 'unmount install\.wim \(commit\)' } | Select-Object -First 1
$verifyCall = $commands | Where-Object { $_.GetCommandName() -eq 'Assert-FeatureEnabled' } | Select-Object -First 1
$guarded = $false
if ($enableCall) {
    $parent = $enableCall.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and $parent.Clauses[0].Item1.Extent.Text -match '^\$EnableNetFx3$') { $guarded = $true }
        $parent = $parent.Parent
    }
}
$offlineSource = $enableCall -and $enableCall.Extent.Text -match "'/LimitAccess'" -and $enableCall.Extent.Text -match '/Source:\$netFx3SourcePath' -and $builderAst.Extent.Text -match '\$netFx3SourcePath\s*=\s*Join-Path \$ScratchDisk ''tiny11\\sources\\sxs'''
$ordered = $enableCall -and $cleanupCall -and $installCommit -and $verifyCall -and
    $cleanupCall.Extent.StartOffset -lt $enableCall.Extent.StartOffset -and
    $enableCall.Extent.StartOffset -lt $verifyCall.Extent.StartOffset -and
    $verifyCall.Extent.StartOffset -lt $installCommit.Extent.StartOffset
if ($guarded -and $offlineSource -and $ordered) { Pass "TEST N3" } else { Fail "TEST N3" "enable=$([bool]$enableCall) guarded=$guarded offline-source=$offlineSource ordered=$ordered" }

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

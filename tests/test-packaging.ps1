<#
.SYNOPSIS
    Install image packaging tests.
.DESCRIPTION
    install.wim (/Compress:max) is the default output because it can be
    mounted and validated; install.esd (/Compress:recovery) is opt-in.
    Executes the builder's real param() block and inspects the export path.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$paramBlockText = $builderAst.ParamBlock.Extent.Text

# ---------------------------------------------------------------------------
# TEST P1 — Default install image format is WIM
# ---------------------------------------------------------------------------
Write-Host "=== TEST P1: Default format is wim ==="
$probe = [scriptblock]::Create("$paramBlockText`n`$InstallImageFormat")
$default = & $probe
if ($default -eq 'wim') { Pass "TEST P1" } else { Fail "TEST P1" "default=[$default]" }

# ---------------------------------------------------------------------------
# TEST P2 — Only wim and esd are accepted
# ---------------------------------------------------------------------------
Write-Host "=== TEST P2: Format is validated ==="
$esd = & $probe -InstallImageFormat 'esd'
$invalidRejected = $false
try { & $probe -InstallImageFormat 'zip' | Out-Null } catch { $invalidRejected = $true }
if ($esd -eq 'esd' -and $invalidRejected) { Pass "TEST P2" } else { Fail "TEST P2" "esd=[$esd] invalid-rejected=$invalidRejected" }

# ---------------------------------------------------------------------------
# TEST P3 — Recovery-compressed ESD export and WIM deletion only happen for esd
# ---------------------------------------------------------------------------
Write-Host "=== TEST P3: ESD export is conditional ==="
function Get-EnclosingIfConditions($node) {
    $conditions = @()
    $parent = $node.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
            $conditions += @($parent.Clauses | ForEach-Object { $_.Item1.Extent.Text })
        }
        $parent = $parent.Parent
    }
    return $conditions
}
$esdExport = @($builderAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Dism' -and $node.Extent.Text -match '/Compress:recovery'
}, $true))
$esdGuarded = @($esdExport | Where-Object { (Get-EnclosingIfConditions $_) -match '\$InstallImageFormat\s+-eq\s+''esd''' })
$wimDeletionAfterEsd = @($builderAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-Item' -and
    $node.Extent.Text -match '\$installImagePath' -and $esdExport.Count -gt 0 -and $node.Extent.StartOffset -gt $esdExport[0].Extent.StartOffset
}, $true))
$deletionGuarded = @($wimDeletionAfterEsd | Where-Object { (Get-EnclosingIfConditions $_) -match '\$InstallImageFormat\s+-eq\s+''esd''' })
if ($esdExport.Count -eq 1 -and $esdGuarded.Count -eq 1 -and $wimDeletionAfterEsd.Count -eq 1 -and $deletionGuarded.Count -eq 1) {
    Pass "TEST P3"
} else {
    Fail "TEST P3" "esd-exports=$($esdExport.Count) guarded=$($esdGuarded.Count) wim-deletions=$($wimDeletionAfterEsd.Count) guarded=$($deletionGuarded.Count)"
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

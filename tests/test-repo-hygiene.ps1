<#
.SYNOPSIS
    Repository hygiene tests.
.DESCRIPTION
    Verifies that builder workspaces and Windows image artifacts cannot be
    staged by accident, while tracked sources stay visible to git.
    Uses git check-ignore only; does not touch the working tree.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Test-GitIgnored {
    param([string]$RelativePath)

    & git -C $repoRoot check-ignore --no-index -q -- $RelativePath
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw "git check-ignore failed for $RelativePath. Exit code: $LASTEXITCODE" }
    }
}

# ---------------------------------------------------------------------------
# TEST A — Build workspaces and image artifacts are ignored
# ---------------------------------------------------------------------------
Write-Host "=== TEST A: Build artifacts ignored ==="
$artifactPaths = @(
    'tiny11/sources/install.wim',
    'tiny11/autorun.inf',
    'scratchdir/Windows/explorer.exe',
    'dism-scratch/1A2B3C4D/package.cab',
    'tiny11_20260924_101500.dism.log',
    'custom.wim',
    'install.esd',
    'install.swm',
    'tiny11.iso',
    'tiny11.iso.manifest.json',
    'tiny11_20260924_101500.log'
)
$notIgnored = @($artifactPaths | Where-Object { -not (Test-GitIgnored $_) })
if ($notIgnored.Count -eq 0) { Pass "TEST A" } else { Fail "TEST A" "not ignored: $($notIgnored -join ', ')" }

# ---------------------------------------------------------------------------
# TEST B — Builder sources are not ignored
# ---------------------------------------------------------------------------
Write-Host "=== TEST B: Sources remain trackable ==="
$sourcePaths = @(
    'tiny11maker.ps1',
    'autounattend.xml',
    'lib/tiny11utils.psm1',
    'lib/tiny11gui.psm1',
    'docs/00-PROJECT-SCOPE.md',
    'tests/test-repo-hygiene.ps1'
)
$wronglyIgnored = @($sourcePaths | Where-Object { Test-GitIgnored $_ })
if ($wronglyIgnored.Count -eq 0) { Pass "TEST B" } else { Fail "TEST B" "ignored: $($wronglyIgnored -join ', ')" }

# ---------------------------------------------------------------------------
# TEST C — Importing the builder modules does not rewrite tracked files
# (runs against a temporary copy of lib\ so the repository is never touched)
# ---------------------------------------------------------------------------
Write-Host "=== TEST C: Module import has no file side effects ==="
$libCopy = Join-Path ([System.IO.Path]::GetTempPath()) "hygiene-lib-$(New-Guid)"
Copy-Item -LiteralPath (Join-Path $repoRoot 'lib') -Destination $libCopy -Recurse
try {
    $hashesBefore = @{}
    Get-ChildItem -LiteralPath $libCopy -File | ForEach-Object { $hashesBefore[$_.Name] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    $importScript = "Import-Module '$libCopy\tiny11utils.psm1'; Import-Module '$libCopy\tiny11gui.psm1'"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $importScript 2>&1 | Out-Null
    $importExitCode = $LASTEXITCODE
    $changedFiles = @(Get-ChildItem -LiteralPath $libCopy -File | Where-Object {
        -not $hashesBefore.ContainsKey($_.Name) -or $hashesBefore[$_.Name] -ne (Get-FileHash -LiteralPath $_.FullName).Hash
    } | ForEach-Object { $_.Name })
    if ($importExitCode -eq 0 -and $changedFiles.Count -eq 0) {
        Pass "TEST C"
    } else {
        Fail "TEST C" "import-exit=$importExitCode files changed by import: $($changedFiles -join ', ')"
    }
} finally {
    Remove-Item -LiteralPath $libCopy -Recurse -Force
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

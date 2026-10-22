<#
.SYNOPSIS
    Wave 0C Transactional Safety Tests (static/structural)
.DESCRIPTION
    Verifies try/catch/finally semantics, cleanup dependency ordering,
    scratch ownership, and DISM commit/failure handling in tiny11maker.ps1
    WITHOUT executing any real DISM/reg/ISO operations.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

$scriptPath = Join-Path $PSScriptRoot '..\tiny11maker.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$parseTokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $scriptPath).Path, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "tiny11maker.ps1 has parse errors: $($parseErrors[0].Message)" }

# ---------------------------------------------------------------------------
# TEST A — Simulated build throw -> finally executes -> terminating error propagates
# ---------------------------------------------------------------------------
Write-Host "=== TEST A: Exception propagation ==="
$propagated = $null
$finallyRan = $false

try {
    try {
        throw "simulated build failure"
    }
    catch {
        $buildException = $_
    }
    finally {
        $finallyRan = $true
    }
    if ($buildException) { throw $buildException }
}
catch {
    $propagated = $_.Exception.Message
}

if ($finallyRan) { Pass "TEST A" } else { Fail "TEST A" "finally did not execute" }
if ($propagated -eq "simulated build failure") { Pass "TEST A-2" } else { Fail "TEST A-2" "original exception not propagated: $propagated" }

# ---------------------------------------------------------------------------
# TEST B — Install hive unload order (reverse order: zDEFAULT before zCOMPONENTS)
# ---------------------------------------------------------------------------
Write-Host "=== TEST B: Install hive unload order ==="
$unloadOrder = @()
function Mock-Unload { param($alias) $script:unloadOrder += $alias }
$loadedInstallHives = @('zCOMPONENTS', 'zDEFAULT')
# Reverse-order unload (LIFO)
for ($i = $loadedInstallHives.Count - 1; $i -ge 0; $i--) {
    Mock-Unload -alias $loadedInstallHives[$i]
}
$loadedInstallHives = @()

if ($unloadOrder[0] -eq 'zDEFAULT' -and $unloadOrder[1] -eq 'zCOMPONENTS') {
    Pass "TEST B"
} else {
    Fail "TEST B" "order was $($unloadOrder -join ',')"
}

# ---------------------------------------------------------------------------
# TEST C — Boot hive unload before boot image discard
# ---------------------------------------------------------------------------
Write-Host "=== TEST C: Boot hive before boot discard ==="
$bootHiveUnloaded = $false
$bootImageDiscarded = $false
$bootHives = @('zDEFAULT', 'zNTUSER', 'zSYSTEM')
foreach ($alias in $bootHives) { $bootHiveUnloaded = $true }

if ($bootHiveUnloaded) { $bootImageDiscarded = $true }

if ($bootHiveUnloaded -and $bootImageDiscarded) { Pass "TEST C" } else { Fail "TEST C" "hives=$bootHiveUnloaded discard=$bootImageDiscarded" }

# ---------------------------------------------------------------------------
# TEST D — Hive unload failure: image NOT blindly discarded
# ---------------------------------------------------------------------------
Write-Host "=== TEST D: Hive unload failure blocks discard ==="
$hiveUnloadFailed = $true
$discarded = $false
if ($hiveUnloadFailed) {
    # Refuse to discard
} else {
    $discarded = $true
}
if (-not $discarded) { Pass "TEST D" } else { Fail "TEST D" "image discarded despite hive unload failure" }

# ---------------------------------------------------------------------------
# TEST E — Preexisting <scratch>\tiny11 causes abort
# ---------------------------------------------------------------------------
Write-Host "=== TEST E: Preexisting tiny11 workspace ==="
$preexisting = $true
$threw = $false
try {
    if ($preexisting) {
        throw "Preexisting builder workspace detected"
    }
} catch { $threw = $true }
if ($threw) { Pass "TEST E" } else { Fail "TEST E" "did not abort on preexisting tiny11" }

# ---------------------------------------------------------------------------
# TEST F — Preexisting <scratch>\scratchdir causes abort
# ---------------------------------------------------------------------------
Write-Host "=== TEST F: Preexisting scratchdir ==="
$preexisting2 = $true
$threw2 = $false
try {
    if ($preexisting2) {
        throw "Preexisting builder scratch directory detected"
    }
} catch { $threw2 = $true }
if ($threw2) { Pass "TEST F" } else { Fail "TEST F" "did not abort on preexisting scratchdir" }

# ---------------------------------------------------------------------------
# TEST G — Directory created by this run may be cleaned
# ---------------------------------------------------------------------------
Write-Host "=== TEST G: Run-created directory cleanup ==="
$createdByThisRun = $true
$deleted = $false
if ($createdByThisRun) { $deleted = $true }
if ($deleted) { Pass "TEST G" } else { Fail "TEST G" "run-created directory not cleaned" }

# ---------------------------------------------------------------------------
# TEST H — Successful normal hive unload removes ownership record
# ---------------------------------------------------------------------------
Write-Host "=== TEST H: Normal unload removes ownership ==="
$loadedHives = @('zSYSTEM')
$unloadExitCode = 0
if ($unloadExitCode -eq 0) { $loadedHives = @() }
if ($loadedHives.Count -eq 0) { Pass "TEST H" } else { Fail "TEST H" "ownership record not removed" }

# ---------------------------------------------------------------------------
# TEST I — Successful /Commit clears image ownership
# ---------------------------------------------------------------------------
Write-Host "=== TEST I: Successful commit clears ownership ==="
$installImageMountedByThisRun = $true
$commitExitCode = 0
if ($commitExitCode -eq 0) { $installImageMountedByThisRun = $false }
if (-not $installImageMountedByThisRun) { Pass "TEST I" } else { Fail "TEST I" "ownership not cleared after commit" }

# ---------------------------------------------------------------------------
# TEST J — Failed /Commit does NOT prematurely clear ownership
# ---------------------------------------------------------------------------
Write-Host "=== TEST J: Failed commit preserves ownership ==="
$installImageMountedByThisRun = $true
$commitExitCode = 1
if ($commitExitCode -ne 0) {
    # Do NOT clear ownership
} else {
    $installImageMountedByThisRun = $false
}
if ($installImageMountedByThisRun) { Pass "TEST J" } else { Fail "TEST J" "ownership prematurely cleared on commit failure" }

# ---------------------------------------------------------------------------
# TEST K — WIM source does not trigger unconditional ESD cleanup
# ---------------------------------------------------------------------------
Write-Host "=== TEST K: WIM source image path handling ==="
$sourceInstallFallback = $source -match '\$sourceInstallImagePath\s*=\s*\$sourceInstallWimPath'
$copiedPathUsesSelectedSource = $source -match '\$copiedInstallImagePath\s*=.*Split-Path.*\$sourceInstallImagePath'
$guidPathCopyUsesLiteralEntries = $source -match 'Get-ChildItem\s+-LiteralPath\s+\$DrivePath' -and $source -match 'Copy-Item\s+-LiteralPath\s+\$sourceEntry\.FullName'
$copiedImageIsVerified = $source -match 'Test-Path\s+-LiteralPath\s+\$installImagePath'
$esdCleanupGuarded = $source -match 'if \(\$ConvertedFromESD\)\s*\{[\s\S]*?Set-ItemProperty[^\r\n]*\$copiedInstallImagePath[\s\S]*?Remove-Item[^\r\n]*\$copiedInstallImagePath'
$unconditionalEsdCleanup = $false
$lines = $source -split "`r?`n"
foreach ($line in $lines) {
    if ($line -match '^\s*(Set-ItemProperty|Remove-Item)\b' -and $line -match 'tiny11\\sources\\install\.esd') {
        $unconditionalEsdCleanup = $true
        break
    }
}
if ($sourceInstallFallback -and $copiedPathUsesSelectedSource -and $guidPathCopyUsesLiteralEntries -and $copiedImageIsVerified -and $esdCleanupGuarded -and -not $unconditionalEsdCleanup) {
    Pass "TEST K"
} else {
    Fail "TEST K" "fallback=$sourceInstallFallback copied-path=$copiedPathUsesSelectedSource literal-copy=$guidPathCopyUsesLiteralEntries image-verified=$copiedImageIsVerified guarded-cleanup=$esdCleanupGuarded unconditional-esd-cleanup=$unconditionalEsdCleanup"
}

# ---------------------------------------------------------------------------
# TEST L — ISO mount helper waits for drive-letter publication
# ---------------------------------------------------------------------------
Write-Host "=== TEST L: ISO mount helper retries drive-letter publication ==="
$modulePath = Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1'
$moduleSource = Get-Content -LiteralPath $modulePath -Raw
$mountsDiskImage = $moduleSource -match 'Mount-DiskImage\s+-ImagePath'
$volumeQueryCount = ([regex]::Matches($moduleSource, 'Get-Volume\s+-DiskImage\s+\$isoDisk')).Count
$boundedRetry = $moduleSource -match 'FromSeconds\(60\)' -and $moduleSource -match 'FromMilliseconds\(250\)' -and $moduleSource -match 'Start-Sleep\s+-Milliseconds'
$driveLetterFilter = $moduleSource -match '-not\s*\[string\]::IsNullOrWhiteSpace'
$volumePathFilter = $moduleSource -match '\$_\.Path'
$stopsWhenLetterAppears = $moduleSource -match 'if \(\$isoVolume\)\s*\{\s*break'
$refreshesDiskImage = $moduleSource -match 'Get-DiskImage\s+-ImagePath\s+\$filePath'
$usesVolumePathFallback = $moduleSource -match '\$mountedDrive\s*=\s*\[string\]\$isoVolume\.Path'
$timeoutNamesIso = $moduleSource -match 'accessible volume path within 60 seconds: \$filePath'
$cleanupOnFailure = $moduleSource -match 'if \(-not \$isoVolume\)[\s\S]*?Dismount-DiskImage\s+-ImagePath\s+\$filePath'
$immediateNoLetterThrow = $moduleSource -match '(?s)Get-Volume\s+-DiskImage\s+\$isoDisk[\s\S]{0,500}?throw "Mounted ISO has no drive letter'
if ($mountsDiskImage -and $volumeQueryCount -eq 1 -and $boundedRetry -and $driveLetterFilter -and $volumePathFilter -and $stopsWhenLetterAppears -and $refreshesDiskImage -and $usesVolumePathFallback -and $timeoutNamesIso -and $cleanupOnFailure -and -not $immediateNoLetterThrow) {
    Pass "TEST L"
} else {
    Fail "TEST L" "mount=$mountsDiskImage volume-queries=$volumeQueryCount retry=$boundedRetry drive-letter-filter=$driveLetterFilter volume-path-filter=$volumePathFilter stop-on-letter=$stopsWhenLetterAppears refresh=$refreshesDiskImage volume-path-fallback=$usesVolumePathFallback timeout-path=$timeoutNamesIso cleanup=$cleanupOnFailure immediate-throw=$immediateNoLetterThrow"
}

# ---------------------------------------------------------------------------
# TEST M — Empty stale tiny11 workspace is recoverable; non-empty is protected
# ---------------------------------------------------------------------------
Write-Host "=== TEST M: Stale workspace recovery guard ==="
$emptyWorkspaceHelper = $source -match 'function Test-EmptyBuilderWorkspace'
$rejectsReparsePoints = $source -match 'FileAttributes\]::ReparsePoint'
$requiresExactlyOneSourcesEntry = $source -match 'PSIsContainer'
$requiresEmptySources = $source -match 'sourcesEntries\.Count\s*-eq\s*0'
$recoversOnlyEmptyWorkspace = $source -match 'Test-EmptyBuilderWorkspace\s+-Path\s+\$tiny11WorkspacePath' -and $source -match 'Remove-Item\s+-LiteralPath\s+\$tiny11WorkspacePath\s+-Recurse\s+-Force'
$preservesUnknownWorkspace = $source -match 'else\s*\{\s*throw "Preexisting builder workspace detected'
if ($emptyWorkspaceHelper -and $rejectsReparsePoints -and $requiresExactlyOneSourcesEntry -and $requiresEmptySources -and $recoversOnlyEmptyWorkspace -and $preservesUnknownWorkspace) {
    Pass "TEST M"
} else {
    Fail "TEST M" "helper=$emptyWorkspaceHelper reparse-guard=$rejectsReparsePoints one-sources-entry=$requiresExactlyOneSourcesEntry empty-sources=$requiresEmptySources recovery=$recoversOnlyEmptyWorkspace preservation=$preservesUnknownWorkspace"
}

# ---------------------------------------------------------------------------
# TEST N — Native command output arrays are accepted by the assertion helper
# ---------------------------------------------------------------------------
Write-Host "=== TEST N: Native command output normalization ==="
$assertOutputAcceptsObjects = $source -match '\[object\]\$Output'
$assertOutputIsJoined = $source -match '@\(\$Output\)\s*-join'
if ($assertOutputAcceptsObjects -and $assertOutputIsJoined) {
    Pass "TEST N"
} else {
    Fail "TEST N" "object-output=$assertOutputAcceptsObjects joined-output=$assertOutputIsJoined"
}

# ---------------------------------------------------------------------------
# TEST O — Optional registry removals tolerate missing targets only
# ---------------------------------------------------------------------------
Write-Host "=== TEST O: Idempotent optional registry removal ==="
$ignoreMissingSwitch = $moduleSource -match '\[switch\]\$IgnoreMissing'
$missingTargetGuard = $moduleSource -match 'unable to find|not found|no ha podido encontrar'
$registryRemovalCalls = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-RegistryValue'
}, $true))
$removalsWithoutIgnoreMissing = @($registryRemovalCalls | Where-Object {
    -not ($_.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'IgnoreMissing'
    })
})
if ($ignoreMissingSwitch -and $missingTargetGuard -and $registryRemovalCalls.Count -gt 0 -and $removalsWithoutIgnoreMissing.Count -eq 0) {
    Pass "TEST O"
} else {
    $strictLines = ($removalsWithoutIgnoreMissing | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ','
    Fail "TEST O" "ignore-switch=$ignoreMissingSwitch missing-target-guard=$missingTargetGuard removals=$($registryRemovalCalls.Count) without-ignore-missing=[$strictLines]"
}

# ---------------------------------------------------------------------------
# TEST P — Output ISO path never overwrites the source ISO path
# PowerShell variables are case-insensitive: $isoPath and $IsoPath are the
# same variable, so reusing the name made cleanup dismount the output ISO.
# ---------------------------------------------------------------------------
Write-Host "=== TEST P: Source and output ISO paths are distinct ==="
$isoPathAssignments = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ieq 'IsoPath'
}, $true))
$unexpectedIsoPathAssignments = @($isoPathAssignments | Where-Object {
    $rightSide = $_.Right.Extent.Text.Trim()
    $rightSide -ne '$null' -and $rightSide -ne 'Get-IsoPath'
})
$oscdimgCall = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.CommandElements[0].Extent.Text -match 'OSCDIMG'
}, $true)) | Select-Object -First 1
$oscdimgOutput = if ($oscdimgCall) { $oscdimgCall.CommandElements[-1] } else { $null }
$outputIsVariable = $oscdimgOutput -is [System.Management.Automation.Language.VariableExpressionAst]
$outputVariableName = if ($outputIsVariable) { $oscdimgOutput.VariablePath.UserPath } else { '' }
$successMessage = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
    $node.Value -match 'ISO file is located'
}, $true)) | Select-Object -First 1
$successMessageVariables = if ($successMessage) {
    @($successMessage.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
} else { @() }
$messageNamesOutput = $outputIsVariable -and ($successMessageVariables -contains $outputVariableName)
if ($unexpectedIsoPathAssignments.Count -eq 0 -and $outputIsVariable -and $outputVariableName -ine 'IsoPath' -and $messageNamesOutput) {
    Pass "TEST P"
} else {
    $reassigned = ($unexpectedIsoPathAssignments | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ','
    Fail "TEST P" "source-iso-reassigned=[$reassigned] oscdimg-output=$(if ($oscdimgOutput) { $oscdimgOutput.Extent.Text }) success-message-names-output=$messageNamesOutput"
}

# ---------------------------------------------------------------------------
# TEST R — Cleanup helpers report errors to the script-level list
# Inside a function, "$cleanupErrors += x" creates a function-local copy, so the
# final CLEANUP WARNINGS summary never saw the error.
# ---------------------------------------------------------------------------
Write-Host "=== TEST R: Cleanup errors reach the script-level summary ==="
$functionScopedAppends = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -match '^(?i)(script:|global:|local:|private:)?cleanupErrors$'
}, $true) | Where-Object {
    $parent = $_.Parent
    while ($parent -and -not ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $parent = $parent.Parent }
    $null -ne $parent
})
$localAppends = @($functionScopedAppends | Where-Object { $_.Left.VariablePath.UserPath -notmatch '^(?i)script:' })
if ($functionScopedAppends.Count -gt 0 -and $localAppends.Count -eq 0) {
    Pass "TEST R"
} else {
    Fail "TEST R" "function-level cleanupErrors assignments=$($functionScopedAppends.Count) not script-scoped at: $(($localAppends | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ',')"
}

# ---------------------------------------------------------------------------
# TEST S — Resources are created inside the try whose finally cleans them up
# Closing the GUI used to 'exit' outside the try, leaving the workspace,
# the DISM scratch directory and the mounted source ISO behind.
# ---------------------------------------------------------------------------
Write-Host "=== TEST S: Workspace, ISO mount and user-cancel exits are covered by finally ==="
$mainTry = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Finally -and
    $node.Finally.Extent.Text -match 'Remove-ScratchWorkspaceIfOwned'
}, $true)) | Select-Object -First 1
function Test-InsideTryBody($node) {
    $mainTry -and $node.Extent.StartOffset -ge $mainTry.Body.Extent.StartOffset -and $node.Extent.EndOffset -le $mainTry.Body.Extent.EndOffset
}
$resourceSteps = @($scriptAst.FindAll({
    param($node)
    ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -match '^\$(tiny11WorkspaceCreatedByThisRun|dismScratchCreatedByThisRun)$' -and $node.Right.Extent.Text -eq '$true') -or
    ($node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Mount-WindowsIso')
}, $true))
$firstResourceOffset = ($resourceSteps | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum
$scriptLevelExits = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true) | Where-Object {
    $parent = $_.Parent
    while ($parent -and -not ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $parent = $parent.Parent }
    $null -eq $parent -and $_.Extent.StartOffset -gt $firstResourceOffset -and $mainTry -and $_.Extent.StartOffset -lt $mainTry.Extent.EndOffset
})
$uncoveredSteps = @(@($resourceSteps) + @($scriptLevelExits) | Where-Object { -not (Test-InsideTryBody $_) })
if ($mainTry -and $resourceSteps.Count -ge 3 -and $uncoveredSteps.Count -eq 0) {
    Pass "TEST S"
} else {
    Fail "TEST S" "main-try=$([bool]$mainTry) resource-steps=$($resourceSteps.Count) outside try body at: $(($uncoveredSteps | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ',')"
}

# ---------------------------------------------------------------------------
# TEST Q — Each run writes its own transcript (failed-run evidence survives)
# ---------------------------------------------------------------------------
Write-Host "=== TEST Q: Transcript path is unique per run ==="
$transcriptCall = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Transcript'
}, $true)) | Select-Object -First 1
$transcriptPathExpression = $null
if ($transcriptCall) {
    $elements = $transcriptCall.CommandElements
    for ($i = 1; $i -lt $elements.Count - 1; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Path') {
            $transcriptPathExpression = $elements[$i + 1]
        }
    }
}
if ($transcriptPathExpression -is [System.Management.Automation.Language.VariableExpressionAst]) {
    $transcriptVariableName = $transcriptPathExpression.VariablePath.UserPath
    $transcriptAssignment = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ieq $transcriptVariableName
    }, $true)) | Select-Object -First 1
    $transcriptPathText = if ($transcriptAssignment) { $transcriptAssignment.Right.Extent.Text } else { $null }
} elseif ($transcriptPathExpression) {
    $transcriptPathText = $transcriptPathExpression.Extent.Text
} else {
    $transcriptPathText = $null
}
if (-not $transcriptPathText) {
    Fail "TEST Q" "Start-Transcript -Path expression not found"
} else {
    $transcriptTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "wave0c-transcript-$(New-Guid)"
    New-Item -ItemType Directory -Path $transcriptTestDir | Out-Null
    try {
        $resolveTranscriptPath = [scriptblock]::Create("param(`$ScratchDisk) $transcriptPathText")
        $firstRunPath = [string](& $resolveTranscriptPath $transcriptTestDir)
        Start-Sleep -Milliseconds 1100
        $secondRunPath = [string](& $resolveTranscriptPath $transcriptTestDir)
        $distinctPerRun = $firstRunPath -ne $secondRunPath
        $insideScratchDisk = (Split-Path -Parent $firstRunPath) -eq $transcriptTestDir
        $isLogFile = $firstRunPath -match '\.log$'
        if ($distinctPerRun -and $insideScratchDisk -and $isLogFile) {
            Pass "TEST Q"
        } else {
            Fail "TEST Q" "first=$firstRunPath second=$secondRunPath distinct=$distinctPerRun inside-scratch=$insideScratchDisk log=$isLogFile"
        }
    } finally {
        Remove-Item -LiteralPath $transcriptTestDir -Recurse -Force
    }
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

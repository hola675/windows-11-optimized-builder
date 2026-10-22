<#
.SYNOPSIS
    Wave 1A Balanced V1 component policy static tests.
.DESCRIPTION
    Verifies that removal lists and physical deletion blocks in
    tiny11maker.ps1 match the Balanced V1 component policy.
    Does NOT execute any real DISM/reg/ISO operations.
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
# TEST A — No removal target contains Windows Terminal
# ---------------------------------------------------------------------------
Write-Host "=== TEST A: Windows Terminal absent from removal list ==="
function Get-AssignedStringList([string]$VariableName) {
    $assignment = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ieq $VariableName
    }, $true)) | Select-Object -First 1
    if (-not $assignment) { return $null }
    return @($assignment.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
}
$removalList = Get-AssignedStringList 'packagePrefixes'
$terminalInRemoval = @($removalList | Where-Object { $_ -like 'Microsoft.WindowsTerminal*' })
if ($removalList -and $terminalInRemoval.Count -eq 0) { Pass "TEST A" } else { Fail "TEST A" "removal-list-found=$([bool]$removalList) terminal-entries=$($terminalInRemoval -join ',')" }

# ---------------------------------------------------------------------------
# TEST B — No language capability removal patterns
# ---------------------------------------------------------------------------
Write-Host "=== TEST B: Language capabilities preserved ==="
$patterns = @(
    'LanguageFeatures-Handwriting',
    'LanguageFeatures-OCR',
    'LanguageFeatures-Speech',
    'LanguageFeatures-TextToSpeech'
)
$allFound = $true
foreach ($p in $patterns) {
    if ($source -match [regex]::Escape($p)) {
        $allFound = $false
        Fail "TEST B-$p" "pattern still present"
    }
}
if ($allFound) { Pass "TEST B" }

# ---------------------------------------------------------------------------
# TEST C — No physical deletion of Microsoft-Edge-Webview
# ---------------------------------------------------------------------------
Write-Host "=== TEST C: WebView2 physical deletion absent ==="
$hasTakeown = $source -match 'Microsoft-Edge-Webview'
if (-not $hasTakeown) { Pass "TEST C" } else { Fail "TEST C" "WebView2 deletion still present" }

# ---------------------------------------------------------------------------
# TEST D — No physical deletion of Edge browser directories
# ---------------------------------------------------------------------------
Write-Host "=== TEST D: Edge browser directories preserved ==="
$edgeDelete = $source -match [regex]::Escape('Program Files (x86)\Microsoft\Edge')
if (-not $edgeDelete) { Pass "TEST D" } else { Fail "TEST D" "Edge directory deletion still present" }

# ---------------------------------------------------------------------------
# TEST E — No physical deletion of OneDriveSetup.exe
# ---------------------------------------------------------------------------
Write-Host "=== TEST E: OneDriveSetup.exe preserved ==="
$odDelete = $source -match 'OneDriveSetup\.exe'
if (-not $odDelete) { Pass "TEST E" } else { Fail "TEST E" "OneDriveSetup deletion still present" }

# ---------------------------------------------------------------------------
# TEST F — Paint not in AppX removal list
# ---------------------------------------------------------------------------
Write-Host "=== TEST F: Paint preserved ==="
$paintInList = $source -match "'Microsoft\.MSPaint'" -or $source -match "'Microsoft\.Paint'"
if (-not $paintInList) { Pass "TEST F" } else { Fail "TEST F" "Paint in removal list" }

# ---------------------------------------------------------------------------
# TEST G — Camera not in AppX removal list
# ---------------------------------------------------------------------------
Write-Host "=== TEST G: Camera preserved ==="
$camInList = $source -match "'Microsoft\.WindowsCamera'"
if (-not $camInList) { Pass "TEST G" } else { Fail "TEST G" "Camera in removal list" }

# ---------------------------------------------------------------------------
# TEST H — Sound Recorder not in AppX removal list
# ---------------------------------------------------------------------------
Write-Host "=== TEST H: Sound Recorder preserved ==="
$srInList = $source -match "'Microsoft\.WindowsSoundRecorder'"
if (-not $srInList) { Pass "TEST H" } else { Fail "TEST H" "Sound Recorder in removal list" }

# ---------------------------------------------------------------------------
# TEST I — Quick Assist not in AppX removal list
# ---------------------------------------------------------------------------
Write-Host "=== TEST I: Quick Assist preserved ==="
$qaInList = $source -match "'MicrosoftCorporationII\.QuickAssist'"
if (-not $qaInList) { Pass "TEST I" } else { Fail "TEST I" "Quick Assist in removal list" }

# ---------------------------------------------------------------------------
# TEST J — Sticky Notes not in AppX removal list
# ---------------------------------------------------------------------------
Write-Host "=== TEST J: Sticky Notes preserved ==="
$snInList = $source -match "'Microsoft\.MicrosoftStickyNotes'"
if (-not $snInList) { Pass "TEST J" } else { Fail "TEST J" "Sticky Notes in removal list" }

# ---------------------------------------------------------------------------
# TEST K — Approved safe-remove targets remain present
# ---------------------------------------------------------------------------
Write-Host "=== TEST K: Safe-remove targets present ==="
$safeTargets = @(
    'Clipchamp.Clipchamp',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.Copilot',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Windows.Copilot',
    'Microsoft.Windows.Teams',
    'Microsoft.WindowsFeedbackHub',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MSTeams',
    'MicrosoftTeams'
)
$allPresent = $true
foreach ($t in $safeTargets) {
    if ($source -notmatch [regex]::Escape($t)) {
        $allPresent = $false
        Fail "TEST K-$t" "safe-remove target missing"
    }
}
if ($allPresent) { Pass "TEST K" }

# ---------------------------------------------------------------------------
# TEST L — Xbox/Gaming removal targets absent from first Balanced V1
# ---------------------------------------------------------------------------
Write-Host "=== TEST L: Xbox/Gaming preserved ==="
$xboxTargets = @(
    'Microsoft\.GamingApp',
    'Microsoft\.Xbox\.TCUI',
    'Microsoft\.XboxApp',
    'Microsoft\.XboxGameOverlay',
    'Microsoft\.XboxGamingOverlay',
    'Microsoft\.XboxIdentityProvider',
    'Microsoft\.XboxSpeechToTextOverlay'
)
$xboxFound = $false
foreach ($t in $xboxTargets) {
    if ($source -match [regex]::Escape($t)) { $xboxFound = $true }
}
if (-not $xboxFound) { Pass "TEST L" } else { Fail "TEST L" "Xbox/Gaming removal target present" }

# ---------------------------------------------------------------------------
# TEST M — Modern Media Player removal target absent
# ---------------------------------------------------------------------------
Write-Host "=== TEST M: Modern Media Player preserved ==="
$mediaPlayer = $source -match 'Microsoft-Windows-MediaPlayer-Package'
if (-not $mediaPlayer) { Pass "TEST M" } else { Fail "TEST M" "Media Player removal pattern present" }

# ---------------------------------------------------------------------------
# TEST N — No Windows servicing/security component newly targeted
# ---------------------------------------------------------------------------
Write-Host "=== TEST N: No servicing/security components targeted ==="
$forbidden = @(
    'Windows Defender',
    'Windows Security',
    'Windows Update',
    'Microsoft Store',
    'App Installer',
    'winget',
    'Windows Installer',
    'WMI',
    'Task Scheduler',
    'SFC',
    'WinRE',
    'Credential Manager',
    'WinSxS',
    'Reserved Storage',
    'BitLocker'
)
$violations = $false
foreach ($f in $forbidden) {
    if ($source -match [regex]::Escape($f)) {
        $violations = $true
        Fail "TEST N-$f" "forbidden target referenced"
    }
}
if (-not $violations) { Pass "TEST N" }

# ---------------------------------------------------------------------------
# TEST O — DISM Cleanup-Image must not use /ResetBase
# ---------------------------------------------------------------------------
Write-Host "=== TEST O: ResetBase prohibited ==="
# Detect the actual DISM invocation, not comments or prose.
$cleanupLines = $source -split "`r?`n" | Where-Object { $_ -match '/Cleanup-Image' }
$resetBaseFound = $false
foreach ($line in $cleanupLines) {
    if ($line -match '/ResetBase') {
        $resetBaseFound = $true
        Fail "TEST O" "DISM Cleanup-Image line still uses /ResetBase: $line"
    }
}
if (-not $resetBaseFound) { Pass "TEST O" }

# ---------------------------------------------------------------------------
# TEST P — No physical deletion of Windows scheduled-task files
# ---------------------------------------------------------------------------
Write-Host "=== TEST P: No physical Scheduled Task file deletion ==="
# Detect Remove-Item operations targeting the Tasks directory, not comments.
$taskDeleteFound = $false
$lines = $source -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match 'Remove-Item' -and $line -match 'System32\\Tasks') {
        $taskDeleteFound = $true
        Fail "TEST P" "Remove-Item targets System32\Tasks at line $($i+1): $line"
    }
    # Also catch a tasks path variable consumed by Remove-Item within a few lines
    if ($line -match '\$tasksPath\s*=.*System32\\Tasks') {
        for ($j = $i + 1; $j -lt [math]::Min($i + 20, $lines.Count); $j++) {
            if ($lines[$j] -match 'Remove-Item' -and $lines[$j] -match '\$tasksPath') {
                $taskDeleteFound = $true
                Fail "TEST P" "\$tasksPath used by Remove-Item at line $($j+1): $($lines[$j])"
            }
        }
    }
}
if (-not $taskDeleteFound) { Pass "TEST P" }

# ---------------------------------------------------------------------------
# TEST Q — Component cleanup preserved without ResetBase
# ---------------------------------------------------------------------------
Write-Host "=== TEST Q: Component cleanup preserved ==="
if ($source -match '/StartComponentCleanup') { Pass "TEST Q" } else { Fail "TEST Q" "/StartComponentCleanup missing" }

# ---------------------------------------------------------------------------
# TEST R — Balanced V1 does not remove optional Windows packages
# ---------------------------------------------------------------------------
Write-Host "=== TEST R: Optional Windows packages preserved ==="
$systemPackageRemoval = $lines | Where-Object {
    ($_ -match "&\s+'DISM'.*/Remove-Package") -or ($_ -match '^\s*\$packagePatterns\s*=')
}
if (-not $systemPackageRemoval) { Pass "TEST R" } else { Fail "TEST R" "optional Windows package removal is still present" }

# ---------------------------------------------------------------------------
# TEST S — Edge is kept, so its uninstall registration must be kept too
# ---------------------------------------------------------------------------
Write-Host "=== TEST S: Edge uninstall registration preserved ==="
$registryRemovalTargets = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-RegistryValue'
}, $true) | ForEach-Object { $_.CommandElements[1].Extent.Text.Trim("'", '"') })
$edgeUninstallRemovals = @($registryRemovalTargets | Where-Object { $_ -match '\\Uninstall\\Microsoft Edge' })
if ($edgeUninstallRemovals.Count -eq 0) { Pass "TEST S" } else { Fail "TEST S" "Edge uninstall entries removed: $($edgeUninstallRemovals -join '; ')" }

# ---------------------------------------------------------------------------
# TEST U — Mandatory KEEP apps are verified by the validation gate, never removed
# ---------------------------------------------------------------------------
Write-Host "=== TEST U: Protected app list covers the spec's mandatory AppX components ==="
$protectedList = Get-AssignedStringList 'requiredProvisionedPrefixes'
$mandatoryApps = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsTerminal', 'Microsoft.SecHealthUI')
$missingMandatory = @($mandatoryApps | Where-Object { $protectedList -notcontains $_ })
$protectedAlsoRemoved = @($protectedList | Where-Object { $protected = $_; @($removalList | Where-Object { $protected -like "$_*" }).Count -gt 0 })
if ($protectedList -and $missingMandatory.Count -eq 0 -and $protectedAlsoRemoved.Count -eq 0) {
    Pass "TEST U"
} else {
    Fail "TEST U" "protected-list-found=$([bool]$protectedList) missing=$($missingMandatory -join ',') also-removed=$($protectedAlsoRemoved -join ',')"
}

# ---------------------------------------------------------------------------
# TEST T — Offline registry security descriptors are not modified
# (ownership/ACL changes only existed to delete scheduled tasks, which V1 keeps)
# ---------------------------------------------------------------------------
Write-Host "=== TEST T: Offline registry ACLs untouched ==="
$aclMutations = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member.Extent.Text -in @('SetOwner', 'SetAccessControl', 'SetAccessRule')
}, $true))
$takeOwnershipPrivilege = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Enable-Privilege'
}, $true))
if ($aclMutations.Count -eq 0 -and $takeOwnershipPrivilege.Count -eq 0) {
    Pass "TEST T"
} else {
    $locations = (@($aclMutations) + @($takeOwnershipPrivilege) | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ','
    Fail "TEST T" "registry ACL/ownership mutation present at $locations"
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

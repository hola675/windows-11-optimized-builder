<#
.SYNOPSIS
    DISM resolution and invocation tests.
.DESCRIPTION
    Exercises Resolve-DismExecutable and Invoke-Dism from lib\tiny11utils.psm1.
    Uses fake dism executables (batch files) in a temporary folder whose path
    contains spaces, so no real DISM operation or elevation is needed.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "dism test $(New-Guid)"
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # -----------------------------------------------------------------------
    # Resolve-DismExecutable
    # -----------------------------------------------------------------------
    $adkDism = Join-Path $sandbox 'adk\dism.exe'
    $systemDism = Join-Path $sandbox 'system\dism.exe'
    New-Item -ItemType Directory -Path (Split-Path $adkDism), (Split-Path $systemDism) | Out-Null

    function New-VersionLookup([hashtable]$Versions) {
        $captured = $Versions
        return { param($Path) [version]$captured[$Path] }.GetNewClosure()
    }

    Write-Host "=== TEST R1: ADK DISM preferred over older system DISM ==="
    Set-Content -LiteralPath $adkDism -Value ''
    Set-Content -LiteralPath $systemDism -Value ''
    $resolved = Resolve-DismExecutable -AdkDismPath $adkDism -SystemDismPath $systemDism -GetFileVersion (New-VersionLookup @{ $adkDism = '10.0.26100.2454'; $systemDism = '10.0.19041.3636' })
    if ($resolved.Path -eq $adkDism -and $resolved.Source -eq 'Windows ADK' -and $resolved.Version -eq [version]'10.0.26100.2454') { Pass "TEST R1" } else { Fail "TEST R1" "got $($resolved.Source) $($resolved.Path) $($resolved.Version)" }

    Write-Host "=== TEST R2: Windows 11 host DISM used when ADK is absent ==="
    Remove-Item -LiteralPath $adkDism
    $resolved = Resolve-DismExecutable -AdkDismPath $adkDism -SystemDismPath $systemDism -GetFileVersion (New-VersionLookup @{ $systemDism = '10.0.26100.1' })
    if ($resolved.Path -eq $systemDism -and $resolved.Source -eq 'System') { Pass "TEST R2" } else { Fail "TEST R2" "got $($resolved.Source) $($resolved.Path)" }

    Write-Host "=== TEST R3: Windows 10 DISM without ADK fails explicitly ==="
    $r3Error = $null
    try { Resolve-DismExecutable -AdkDismPath $adkDism -SystemDismPath $systemDism -GetFileVersion (New-VersionLookup @{ $systemDism = '10.0.19041.3636' }) | Out-Null } catch { $r3Error = $_.Exception.Message }
    if ($r3Error -match 'Windows ADK' -and $r3Error -match '10\.0\.26100' -and $r3Error -match '10\.0\.19041\.3636') { Pass "TEST R3" } else { Fail "TEST R3" "error=$r3Error" }

    Write-Host "=== TEST R4: ADK older than 24H2 is rejected ==="
    Set-Content -LiteralPath $adkDism -Value ''
    $r4Error = $null
    try { Resolve-DismExecutable -AdkDismPath $adkDism -SystemDismPath $systemDism -GetFileVersion (New-VersionLookup @{ $adkDism = '10.0.22621.1'; $systemDism = '10.0.19041.3636' }) | Out-Null } catch { $r4Error = $_.Exception.Message }
    if ($r4Error -match '10\.0\.22621\.1') { Pass "TEST R4" } else { Fail "TEST R4" "error=$r4Error" }

    # -----------------------------------------------------------------------
    # Invoke-Dism (fake dism.cmd records its raw command line and TEMP)
    # -----------------------------------------------------------------------
    $fakeDism = Join-Path $sandbox 'fake dism.cmd'
    $argsFile = Join-Path $sandbox 'last-args.txt'
    $envFile = Join-Path $sandbox 'last-env.txt'
    Set-Content -LiteralPath $fakeDism -Encoding ASCII -Value @(
        '@echo off'
        'echo %*> "%~dp0last-args.txt"'
        'echo %TEMP%> "%~dp0last-env.txt"'
        'echo fake dism output line'
        'exit /b %FAKE_DISM_EXIT%'
    )
    $logPath = Join-Path $sandbox 'run.dism.log'
    $scratchDir = Join-Path $sandbox 'dism scratch'
    New-Item -ItemType Directory -Path $scratchDir | Out-Null
    $imageDir = Join-Path $sandbox 'mount dir'

    function Read-FakeArgs { (Get-Content -LiteralPath $argsFile -Raw).Trim() }

    Write-Host "=== TEST I1: Servicing command gets global options, scratch dir and quoting ==="
    $env:FAKE_DISM_EXIT = '0'
    Invoke-Dism -DismPath $fakeDism -Operation 'cleanup image' -LogPath $logPath -ScratchDir $scratchDir -Arguments @("/Image:$imageDir", '/Cleanup-Image', '/StartComponentCleanup')
    $expected = "/English `"/LogPath:$logPath`" `"/ScratchDir:$scratchDir`" `"/Image:$imageDir`" /Cleanup-Image /StartComponentCleanup"
    $actual = Read-FakeArgs
    if ($actual -eq $expected) { Pass "TEST I1" } else { Fail "TEST I1" "expected=[$expected] actual=[$actual]" }

    Write-Host "=== TEST I2: Imaging command has no /ScratchDir but TEMP points to scratch ==="
    Invoke-Dism -DismPath $fakeDism -Operation 'export image' -LogPath $logPath -ScratchDir $scratchDir -Arguments @('/Export-Image', '/SourceImageFile:C:\a.wim', '/SourceIndex:1', '/DestinationImageFile:C:\b.wim')
    $actual = Read-FakeArgs
    $childTemp = (Get-Content -LiteralPath $envFile -Raw).Trim()
    if ($actual -notmatch '/ScratchDir' -and $actual -match '^/English "/LogPath:' -and $childTemp -eq $scratchDir) { Pass "TEST I2" } else { Fail "TEST I2" "args=[$actual] child-TEMP=[$childTemp]" }

    Write-Host "=== TEST I3: Non-zero exit code throws with operation, HRESULT and log ==="
    $env:FAKE_DISM_EXIT = '-2146498529'
    $i3Error = $null
    try { Invoke-Dism -DismPath $fakeDism -Operation 'add package KB1' -LogPath $logPath -ScratchDir $scratchDir -Arguments @("/Image:$imageDir", '/Add-Package', '/PackagePath:C:\p.msu') } catch { $i3Error = $_.Exception.Message }
    if ($i3Error -match 'add package KB1' -and $i3Error -match '0x800F081F' -and $i3Error -match [regex]::Escape($logPath)) { Pass "TEST I3" } else { Fail "TEST I3" "error=$i3Error" }

    Write-Host "=== TEST I4: Explicitly allowed exit code does not throw ==="
    $env:FAKE_DISM_EXIT = '3010'
    $i4Error = $null
    try { Invoke-Dism -DismPath $fakeDism -Operation 'allowed' -LogPath $logPath -ScratchDir $scratchDir -Arguments @('/Get-WimInfo', '/WimFile:C:\a.wim') -AllowedExitCodes 0, 3010 } catch { $i4Error = $_.Exception.Message }
    if (-not $i4Error) { Pass "TEST I4" } else { Fail "TEST I4" "error=$i4Error" }

    Write-Host "=== TEST I5: Capture mode returns output and quotes arguments ==="
    $env:FAKE_DISM_EXIT = '0'
    $captured = @(Invoke-Dism -DismPath $fakeDism -Operation 'get wim info' -LogPath $logPath -ScratchDir $scratchDir -Arguments @('/Get-WimInfo', "/WimFile:$imageDir\install.wim") -CaptureOutput)
    $actual = Read-FakeArgs
    if (($captured -join "`n") -match 'fake dism output line' -and $actual -match [regex]::Escape("/WimFile:$imageDir\install.wim")) { Pass "TEST I5" } else { Fail "TEST I5" "captured=[$($captured -join '|')] args=[$actual]" }

    Write-Host "=== TEST I6: Capture mode failure includes output ==="
    $env:FAKE_DISM_EXIT = '87'
    $i6Error = $null
    try { Invoke-Dism -DismPath $fakeDism -Operation 'bad query' -LogPath $logPath -ScratchDir $scratchDir -Arguments @('/Get-WimInfo') -CaptureOutput | Out-Null } catch { $i6Error = $_.Exception.Message }
    if ($i6Error -match 'bad query' -and $i6Error -match 'Exit code: 87' -and $i6Error -match 'fake dism output line') { Pass "TEST I6" } else { Fail "TEST I6" "error=$i6Error" }

    Write-Host "=== TEST I7: Trailing backslash inside a quoted argument is escaped ==="
    $env:FAKE_DISM_EXIT = '0'
    $trailing = "/MountDir:$imageDir\"
    Invoke-Dism -DismPath $fakeDism -Operation 'trailing slash' -LogPath $logPath -ScratchDir $scratchDir -Arguments @('/Unmount-Image', $trailing, '/Discard')
    $actual = Read-FakeArgs
    if ($actual -match [regex]::Escape("`"$trailing\`"")) { Pass "TEST I7" } else { Fail "TEST I7" "args=[$actual]" }
} finally {
    Remove-Item Env:\FAKE_DISM_EXIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

# ---------------------------------------------------------------------------
# TEST W1 — Builder and modules never call DISM by bare name
# (a bare 'DISM' resolves to the host's System32 DISM, unsupported for 24H2/25H2)
# ---------------------------------------------------------------------------
Write-Host "=== TEST W1: All DISM calls go through Invoke-Dism ==="
$sourceFiles = @(
    (Join-Path $PSScriptRoot '..\tiny11maker.ps1'),
    (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1'),
    (Join-Path $PSScriptRoot '..\lib\tiny11gui.psm1')
)
$bareDismCalls = @()
foreach ($file in $sourceFiles) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$tokens, [ref]$errors)
    $bareDismCalls += @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.CommandElements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.CommandElements[0].Value -match '^(?i)dism(\.exe)?$'
    }, $true) | ForEach-Object { "$(Split-Path -Leaf $file):L$($_.Extent.StartLineNumber)" })
}
if ($bareDismCalls.Count -eq 0) { Pass "TEST W1" } else { Fail "TEST W1" "bare DISM calls: $($bareDismCalls -join ', ')" }

# ---------------------------------------------------------------------------
# TEST W2 — Builder resolves a supported DISM before using it
# ---------------------------------------------------------------------------
Write-Host "=== TEST W2: Builder resolves DISM ==="
$builderTokens = $null
$builderErrors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$builderTokens, [ref]$builderErrors)
$resolveCalls = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Resolve-DismExecutable' }, $true))
$invokeCalls = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Dism' }, $true))
if ($resolveCalls.Count -eq 1 -and $invokeCalls.Count -gt 0) { Pass "TEST W2" } else { Fail "TEST W2" "resolve-calls=$($resolveCalls.Count) invoke-calls=$($invokeCalls.Count)" }

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

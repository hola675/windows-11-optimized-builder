<#
.SYNOPSIS
    Optional local account tests (BL-006, decision D-006).
.DESCRIPTION
    -LocalAccountName adds a documented unattend local account (Administrators,
    blank password, password change forced at the next sign-in) to the answer
    file written into the image and onto the media. The repository template is
    never modified, and without the parameter it is copied unchanged.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

Import-Module (Join-Path $PSScriptRoot '..\lib\tiny11utils.psm1') -Force

$templatePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\autounattend.xml')).Path
$unattendNamespace = 'urn:schemas-microsoft-com:unattend'
$wcmNamespace = 'http://schemas.microsoft.com/WMIConfig/2002/State'
$shellSetupXPath = "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']"
# Built from char codes: Windows PowerShell 5.1 reads BOM-less scripts as ANSI
$unicodeName = "Jos$([char]0xE9) P$([char]0xE9)rez"

function New-UnattendNamespaceManager {
    param($Document)
    $ns = New-Object System.Xml.XmlNamespaceManager($Document.NameTable)
    $ns.AddNamespace('u', $unattendNamespace)
    # The manager enumerates its prefixes; the comma stops PowerShell from unrolling it
    ,$ns
}

$tokens = $null
$errors = $null
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\tiny11maker.ps1')).Path, [ref]$tokens, [ref]$errors)
$commands = @($builderAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "local account test $(New-Guid)"
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # -----------------------------------------------------------------------
    # TEST L1 — Valid Windows local account names are accepted
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L1: Valid account names are accepted ==="
    $validNames = @('Admin', $unicodeName, 'user.name-1_x', ('a' * 20))
    $rejected = @($validNames | Where-Object { $candidate = $_; try { Assert-LocalAccountName -Name $candidate; $false } catch { $true } })
    if ($rejected.Count -eq 0) { Pass "TEST L1" } else { Fail "TEST L1" "rejected: $($rejected -join ' | ')" }

    # -----------------------------------------------------------------------
    # TEST L2 — Invalid, reserved and existing built-in names are rejected
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L2: Invalid and reserved account names are rejected ==="
    $invalidNames = @('', '   ', 'NONE', 'administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', ('a' * 21), 'a/b', 'a"b', 'a@b', 'a%b', 'a&b', ' lead', 'trail.', 'trail ')
    $accepted = @($invalidNames | Where-Object { $candidate = $_; try { Assert-LocalAccountName -Name $candidate; $true } catch { $false } })
    $message = $null
    try { Assert-LocalAccountName -Name 'a/b' } catch { $message = $_.Exception.Message }
    if ($accepted.Count -eq 0 -and $message -match 'LocalAccountName' -and $message -match 'a/b') { Pass "TEST L2" } else { Fail "TEST L2" "accepted: [$($accepted -join ' | ')] message=$message" }

    # -----------------------------------------------------------------------
    # TEST L3 — Generated answer file declares the account (oobeSystem)
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L3: Account is declared in oobeSystem Shell-Setup ==="
    $document = New-UnattendWithLocalAccount -TemplatePath $templatePath -AccountName $unicodeName
    $ns = New-UnattendNamespaceManager $document
    $shellSetup = @($document.SelectNodes($shellSetupXPath, $ns))
    $account = $document.SelectSingleNode("$shellSetupXPath/u:UserAccounts/u:LocalAccounts/u:LocalAccount", $ns)
    $checks = @(
        ($shellSetup.Count -eq 1),
        ($null -ne $account),
        ($account -and $account.GetAttribute('action', $wcmNamespace) -eq 'add'),
        ($account -and $account.SelectSingleNode('u:Name', $ns).InnerText -eq $unicodeName),
        ($account -and $account.SelectSingleNode('u:Group', $ns).InnerText -eq 'Administrators'),
        ($account -and $account.SelectSingleNode('u:Password/u:Value', $ns) -and $account.SelectSingleNode('u:Password/u:Value', $ns).InnerText -eq ''),
        ($account -and $account.SelectSingleNode('u:Password/u:PlainText', $ns).InnerText -eq 'true')
    )
    if ($checks -notcontains $false) { Pass "TEST L3" } else { Fail "TEST L3" "checks=$($checks -join ',')" }

    # -----------------------------------------------------------------------
    # TEST L4 — First sign-in forces a password change at the next sign-in
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L4: FirstLogonCommands forces the password change ==="
    $command = $document.SelectSingleNode("$shellSetupXPath/u:FirstLogonCommands/u:SynchronousCommand", $ns)
    $checks = @(
        ($null -ne $command),
        ($command -and $command.GetAttribute('action', $wcmNamespace) -eq 'add'),
        ($command -and $command.SelectSingleNode('u:Order', $ns).InnerText -eq '1'),
        ($command -and $command.SelectSingleNode('u:CommandLine', $ns).InnerText -eq "net user `"$unicodeName`" /logonpasswordchg:yes")
    )
    if ($checks -notcontains $false) { Pass "TEST L4" } else { Fail "TEST L4" "checks=$($checks -join ',') command=$(if ($command) { $command.OuterXml })" }

    # -----------------------------------------------------------------------
    # TEST L5 — The rest of the template is preserved and the file round-trips
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L5: Template settings preserved; saved file keeps the Unicode name ==="
    $savedPath = Join-Path $sandbox 'generated\autounattend.xml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $savedPath) | Out-Null
    Write-AnswerFile -TemplatePath $templatePath -Destination $savedPath -Document $document
    $saved = New-Object System.Xml.XmlDocument
    $saved.Load($savedPath)
    $savedNs = New-UnattendNamespaceManager $saved
    $checks = @(
        ($saved.SelectSingleNode("$shellSetupXPath/u:OOBE/u:HideOnlineAccountScreens", $savedNs).InnerText -eq 'true'),
        ($saved.SelectSingleNode('//u:ConfigureChatAutoInstall', $savedNs).InnerText -eq 'false'),
        ($saved.SelectSingleNode("//u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData[u:Key='/IMAGE/INDEX']/u:Value", $savedNs).InnerText -eq '1'),
        ($saved.SelectSingleNode("$shellSetupXPath/u:UserAccounts/u:LocalAccounts/u:LocalAccount/u:Name", $savedNs).InnerText -eq $unicodeName)
    )
    if ($checks -notcontains $false) { Pass "TEST L5" } else { Fail "TEST L5" "checks=$($checks -join ',')" }

    # -----------------------------------------------------------------------
    # TEST L12 — The saved blank password is empty, not indentation whitespace
    # (a default XmlDocument load drops whitespace-only text, so read it preserved)
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L12: Saved password value is truly empty ==="
    $raw = New-Object System.Xml.XmlDocument
    $raw.PreserveWhitespace = $true
    $raw.Load($savedPath)
    $rawValue = $raw.SelectSingleNode("$shellSetupXPath/u:UserAccounts/u:LocalAccounts/u:LocalAccount/u:Password/u:Value", (New-UnattendNamespaceManager $raw))
    if ($rawValue -and $rawValue.InnerText -eq '') { Pass "TEST L12" } else { Fail "TEST L12" "Value=[$(if ($rawValue) { $rawValue.InnerText -replace "`r?`n", '\n' } else { '<missing>' })]" }

    # -----------------------------------------------------------------------
    # TEST L6 — Template is never modified; without a document it is copied byte for byte
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L6: Template untouched; copy mode is byte-identical ==="
    $templateHashBefore = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash
    $copiedPath = Join-Path $sandbox 'copied\autounattend.xml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $copiedPath) | Out-Null
    $null = New-UnattendWithLocalAccount -TemplatePath $templatePath -AccountName 'Admin'
    Write-AnswerFile -TemplatePath $templatePath -Destination $copiedPath
    $templateHashAfter = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash
    $copiedHash = (Get-FileHash -LiteralPath $copiedPath -Algorithm SHA256).Hash
    if ($templateHashBefore -eq $templateHashAfter -and $copiedHash -eq $templateHashBefore) { Pass "TEST L6" } else { Fail "TEST L6" "before=$templateHashBefore after=$templateHashAfter copy=$copiedHash" }

    # -----------------------------------------------------------------------
    # TEST L7 — A template without an oobeSystem Shell-Setup component fails loudly
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L7: Template without oobeSystem Shell-Setup is rejected ==="
    $brokenTemplate = Join-Path $sandbox 'broken.xml'
    Set-Content -LiteralPath $brokenTemplate -Encoding UTF8 -Value '<?xml version="1.0" encoding="utf-8"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="windowsPE"/></unattend>'
    $brokenError = $null
    try { $null = New-UnattendWithLocalAccount -TemplatePath $brokenTemplate -AccountName 'Admin' } catch { $brokenError = $_.Exception.Message }
    if ($brokenError -match 'oobeSystem' -and $brokenError -match 'Microsoft-Windows-Shell-Setup') { Pass "TEST L7" } else { Fail "TEST L7" "error=$brokenError" }

    # -----------------------------------------------------------------------
    # TEST L8 — Manifest records the account name, null when not requested
    # -----------------------------------------------------------------------
    Write-Host "=== TEST L8: Manifest records servicing.localAccount ==="
    $outputIso = Join-Path $sandbox 'tiny11.iso'
    [System.IO.File]::WriteAllBytes($outputIso, [System.Text.Encoding]::ASCII.GetBytes('abc'))
    $dism = [pscustomobject]@{ Path = 'x'; Version = [version]'10.0.26100.1'; Source = 'System' }
    $withAccount = (New-BuildManifest -OutputIsoPath $outputIso -Dism $dism -LocalAccountName 'Admin' | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    $withoutAccount = (New-BuildManifest -OutputIsoPath $outputIso -Dism $dism | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    $builderPassesIt = @($commands | Where-Object { $_.GetCommandName() -eq 'New-BuildManifest' -and $_.Extent.Text -match '-LocalAccountName \$LocalAccountName' }).Count -eq 1
    if ($withAccount.servicing.localAccount -eq 'Admin' -and $null -eq $withoutAccount.servicing.localAccount -and $builderPassesIt) { Pass "TEST L8" } else { Fail "TEST L8" "with=$($withAccount.servicing.localAccount) without=$($withoutAccount.servicing.localAccount) builder=$builderPassesIt" }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

# ---------------------------------------------------------------------------
# TEST L9 — Builder: parameter is optional and validated before any work starts
# ---------------------------------------------------------------------------
Write-Host "=== TEST L9: -LocalAccountName is optional and validated early ==="
$probe = [scriptblock]::Create("$($builderAst.ParamBlock.Extent.Text)`n`$LocalAccountName")
$default = & $probe
$assertCall = $commands | Where-Object { $_.GetCommandName() -eq 'Assert-LocalAccountName' } | Select-Object -First 1
$transcriptCall = $commands | Where-Object { $_.GetCommandName() -eq 'Start-Transcript' } | Select-Object -First 1
$guarded = $false
if ($assertCall) {
    $parent = $assertCall.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and $parent.Clauses[0].Item1.Extent.Text -match '^\$LocalAccountName$') { $guarded = $true }
        $parent = $parent.Parent
    }
}
$early = $assertCall -and $transcriptCall -and $assertCall.Extent.StartOffset -lt $transcriptCall.Extent.StartOffset
if ([string]::IsNullOrEmpty($default) -and $guarded -and $early) { Pass "TEST L9" } else { Fail "TEST L9" "default='$default' assert=$([bool]$assertCall) guarded=$guarded early=$early" }

# ---------------------------------------------------------------------------
# TEST L10 — Builder writes the same answer file into the image and onto the media
# ---------------------------------------------------------------------------
Write-Host "=== TEST L10: Image and media answer files come from one source ==="
$writes = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-AnswerFile' })
$imageWrite = @($writes | Where-Object { $_.Extent.Text -match 'scratchdir\\Windows\\System32\\Sysprep\\autounattend\.xml' })
$mediaWrite = @($writes | Where-Object { $_.Extent.Text -match 'tiny11\\autounattend\.xml' })
$sameDocument = @($writes | Where-Object { $_.Extent.Text -match '-Document \$answerFileDocument' }).Count -eq 2
$documentBuilt = @($commands | Where-Object { $_.GetCommandName() -eq 'New-UnattendWithLocalAccount' -and $_.Extent.Text -match '-AccountName \$LocalAccountName' }).Count -eq 1
$rawCopies = @($commands | Where-Object { $_.GetCommandName() -eq 'Copy-Item' -and $_.Extent.Text -match 'autounattend\.xml' })
if ($writes.Count -eq 2 -and $imageWrite.Count -eq 1 -and $mediaWrite.Count -eq 1 -and $sameDocument -and $documentBuilt -and $rawCopies.Count -eq 0) { Pass "TEST L10" } else { Fail "TEST L10" "writes=$($writes.Count) image=$($imageWrite.Count) media=$($mediaWrite.Count) same-document=$sameDocument built=$documentBuilt raw-copies=$($rawCopies.Count)" }

# ---------------------------------------------------------------------------
# TEST L11 — The repository template carries no account and no password
# ---------------------------------------------------------------------------
Write-Host "=== TEST L11: Repository template has no accounts or passwords ==="
$template = New-Object System.Xml.XmlDocument
$template.Load($templatePath)
$templateNs = New-UnattendNamespaceManager $template
$secrets = @($template.SelectNodes('//u:UserAccounts | //u:Password | //u:AutoLogon | //u:AdministratorPassword', $templateNs))
if ($secrets.Count -eq 0) { Pass "TEST L11" } else { Fail "TEST L11" "found: $(($secrets | ForEach-Object { $_.LocalName }) -join ', ')" }

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

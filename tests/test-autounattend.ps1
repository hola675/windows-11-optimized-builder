<#
.SYNOPSIS
    autounattend.xml structure tests.
.DESCRIPTION
    Parses autounattend.xml and checks it against documented unattend rules:
    every component lives in a configuration pass, settings sit in passes
    where Microsoft documents them as valid, and the image index matches the
    single-index image the builder exports.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Pass { param($name); $script:passCount++; Write-Host "PASS $name" -ForegroundColor Green }
function Fail { param($name, $msg); $script:failCount++; Write-Host "FAIL $name : $msg" -ForegroundColor Red }

$answerFilePath = Join-Path $PSScriptRoot '..\autounattend.xml'
$unattendNamespace = 'urn:schemas-microsoft-com:unattend'
$validPasses = @('windowsPE', 'offlineServicing', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem')

# ---------------------------------------------------------------------------
# TEST A — Answer file is well-formed unattend XML
# ---------------------------------------------------------------------------
Write-Host "=== TEST A: Well-formed unattend XML ==="
$answerFile = $null
try {
    $answerFile = New-Object System.Xml.XmlDocument
    $answerFile.Load((Resolve-Path -LiteralPath $answerFilePath).Path)
} catch {
    $answerFile = $null
    Fail "TEST A" "XML parse error: $($_.Exception.Message)"
}
if ($answerFile) {
    if ($answerFile.DocumentElement.LocalName -eq 'unattend' -and $answerFile.DocumentElement.NamespaceURI -eq $unattendNamespace) {
        Pass "TEST A"
    } else {
        Fail "TEST A" "root is {$($answerFile.DocumentElement.NamespaceURI)}$($answerFile.DocumentElement.LocalName)"
    }
}
if (-not $answerFile) {
    Write-Host "Tests passed: $passCount"
    Write-Host "Tests failed: $failCount"
    exit 1
}

$ns = New-Object System.Xml.XmlNamespaceManager($answerFile.NameTable)
$ns.AddNamespace('u', $unattendNamespace)

# ---------------------------------------------------------------------------
# TEST B — Every component is inside a valid configuration pass
# (a component outside <settings pass="..."> is not applied by Setup)
# ---------------------------------------------------------------------------
Write-Host "=== TEST B: Components live in valid configuration passes ==="
$misplacedComponents = @($answerFile.SelectNodes('//u:component', $ns) | Where-Object {
    $parent = $_.ParentNode
    -not ($parent.LocalName -eq 'settings' -and $parent.NamespaceURI -eq $unattendNamespace -and $validPasses -contains $parent.GetAttribute('pass'))
})
if ($misplacedComponents.Count -eq 0) {
    Pass "TEST B"
} else {
    Fail "TEST B" "components outside a valid pass: $(($misplacedComponents | ForEach-Object { "$($_.GetAttribute('name')) under <$($_.ParentNode.LocalName)>" }) -join '; ')"
}

# ---------------------------------------------------------------------------
# TEST C — Teams/Chat auto-install stays disabled in a documented pass
# ConfigureChatAutoInstall is valid in offlineServicing, specialize, oobeSystem
# ---------------------------------------------------------------------------
Write-Host "=== TEST C: ConfigureChatAutoInstall=false in a documented pass ==="
$chatSettings = @($answerFile.SelectNodes('//u:ConfigureChatAutoInstall', $ns))
$effectiveChatSettings = @($chatSettings | Where-Object {
    $component = $_.ParentNode
    $settings = $component.ParentNode
    $_.InnerText.Trim() -ieq 'false' -and
    $component.LocalName -eq 'component' -and $component.GetAttribute('name') -eq 'Microsoft-Windows-Shell-Setup' -and
    $settings.LocalName -eq 'settings' -and @('offlineServicing', 'specialize', 'oobeSystem') -contains $settings.GetAttribute('pass')
})
if ($chatSettings.Count -eq 1 -and $effectiveChatSettings.Count -eq 1) {
    Pass "TEST C"
} else {
    Fail "TEST C" "ConfigureChatAutoInstall entries=$($chatSettings.Count) effective=$($effectiveChatSettings.Count)"
}

# ---------------------------------------------------------------------------
# TEST D — A component name appears at most once per pass
# ---------------------------------------------------------------------------
Write-Host "=== TEST D: No duplicate component per pass ==="
$duplicates = @($answerFile.SelectNodes('//u:settings', $ns) | ForEach-Object {
    $pass = $_.GetAttribute('pass')
    $_.SelectNodes('u:component', $ns) | Group-Object { $_.GetAttribute('name') } | Where-Object Count -gt 1 | ForEach-Object { "$pass/$($_.Name)" }
})
if ($duplicates.Count -eq 0) { Pass "TEST D" } else { Fail "TEST D" "duplicates: $($duplicates -join ', ')" }

# ---------------------------------------------------------------------------
# TEST E — Setup installs index 1 (the builder exports a single-index image)
# ---------------------------------------------------------------------------
Write-Host "=== TEST E: Install image index matches single-index export ==="
$indexValue = $answerFile.SelectSingleNode("//u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData[u:Key='/IMAGE/INDEX']/u:Value", $ns)
if ($indexValue -and $indexValue.InnerText.Trim() -eq '1') { Pass "TEST E" } else { Fail "TEST E" "/IMAGE/INDEX=$(if ($indexValue) { $indexValue.InnerText } else { '<missing>' })" }

# ---------------------------------------------------------------------------
# TEST F — Compact OS is not forced (spec: performance ranks above disk footprint)
# ---------------------------------------------------------------------------
Write-Host "=== TEST F: Compact OS not forced ==="
$compactSetting = $answerFile.SelectSingleNode('//u:ImageInstall/u:OSImage/u:Compact', $ns)
if (-not $compactSetting -or $compactSetting.InnerText.Trim() -ine 'true') { Pass "TEST F" } else { Fail "TEST F" "OSImage/Compact=$($compactSetting.InnerText)" }

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

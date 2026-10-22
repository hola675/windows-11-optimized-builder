$ErrorActionPreference = 'Stop'
$profilePath = Join-Path $PSScriptRoot '..\profiles\balanced-developer.json'
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

if ($profile.schemaVersion -ne 1) { throw 'schemaVersion must be 1' }
if ($profile.profile -ne 'balanced-developer') { throw 'Unexpected profile name' }
if ($profile.hardwareRequirementBypass -ne $false) { throw 'Hardware requirement bypass must be false by default' }
if ($profile.privacy.claimZeroTelemetry -ne $false) { throw 'The profile must not claim zero telemetry' }
if ($profile.privacy.applyUnverifiedRegistryTweaks -ne $false) { throw 'Unverified registry tweaks must be disabled' }

$required = @('WindowsUpdate','MicrosoftDefender','MicrosoftStore','AppInstaller','winget','PowerShell','WindowsTerminal','WebView2','DISM','SFC','WinRE','Networking','VPN')
foreach ($capability in $required) {
    if ($profile.preserveCapabilities -notcontains $capability) {
        throw "Protected capability missing from profile: $capability"
    }
}
Write-Host 'Profile manifest validation passed.'

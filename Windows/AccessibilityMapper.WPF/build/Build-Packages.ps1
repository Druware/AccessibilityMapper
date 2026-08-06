<#
.SYNOPSIS
    Builds Accessibility Mapper MSIX packages for the Microsoft Store and for direct
    distribution.

.DESCRIPTION
    Publishes the app self-contained for each requested architecture, lays out an MSIX
    package around each publish output, indexes the scaled logo assets into a
    resources.pri, packs one .msix per architecture, and combines them into a single
    .msixbundle.

    The two channels differ only in package identity and signing:

      -Channel Store    Identity is left exactly as authored in Package.appxmanifest,
                        which must carry your Partner Center values. The bundle is NOT
                        signed - Microsoft re-signs it during ingestion. Upload the
                        .msixbundle to Partner Center.

      -Channel Direct   Identity Publisher is rewritten to the subject of the signing
                        certificate so the two always agree, the bundle is signed, and an
                        .appinstaller update feed is emitted alongside it.

    Requires the Windows SDK (makeappx/makepri/signtool) and the .NET SDK. Nothing is
    installed or modified outside the output directory.

.PARAMETER Channel
    Store or Direct. See above.

.PARAMETER Architectures
    Any of x64, arm64, x86. x64 and arm64 by default: Windows 11 has no x86 edition, so
    x86 only serves 32-bit Windows 10 holdouts and is not worth a third of the bundle size
    by default. It stays supported and builds on request:

        -Architectures x64,arm64,x86

    Narrow it (e.g. -Architectures x64) for a faster loop while iterating.

.PARAMETER CertificateThumbprint
    Thumbprint of a code-signing certificate in Cert:\CurrentUser\My. Direct channel only.

.PARAMETER CertificatePath
    Path to a .pfx, as an alternative to -CertificateThumbprint. Direct channel only.

.PARAMETER CertificatePassword
    Password for -CertificatePath, if it has one.

.PARAMETER UpdateUrl
    Base URL the .appinstaller feed will be published under. Direct channel only.

.PARAMETER ReadyToRun
    Precompile to native code. Larger packages, noticeably faster cold start.

.PARAMETER SkipSign
    Produce an unsigned Direct build (it will not install without further signing).

.EXAMPLE
    pwsh -File build/Build-Packages.ps1 -Channel Store

.EXAMPLE
    pwsh -File build/Build-Packages.ps1 -Channel Direct `
        -CertificateThumbprint A1B2C3... -UpdateUrl https://druware.com/accessibilitymapper
#>
[CmdletBinding()]
param(
    [ValidateSet('Store', 'Direct')]
    [string]$Channel = 'Direct',

    [ValidateSet('x64', 'arm64', 'x86')]
    [string[]]$Architectures = @('x64', 'arm64'),

    [string]$Configuration = 'Release',

    [string]$CertificateThumbprint,
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    [string]$UpdateUrl = 'https://druware.com/accessibilitymapper',

    [string]$IdentityName,
    [string]$Publisher,

    [switch]$ReadyToRun,
    [switch]$SkipSign
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot 'src\AccessibilityMapper.App\AccessibilityMapper.App.csproj'
$packageDir  = Join-Path $PSScriptRoot 'Package'
$outputDir   = Join-Path $PSScriptRoot 'out'
$stagingDir  = Join-Path $PSScriptRoot 'staging'

# Set once the staging tree exists; Invoke-Tool logs to it from that point on.
$script:logDirectory = $null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

<# Runs a build tool, tucking its (very chatty - makeappx lists every packaged file)
   output into build/staging/logs and surfacing it only when the tool fails. NUL bytes
   are stripped because makepri writes UTF-16 that the console decodes as ANSI. #>
function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Activity
    )

    $output = & $FilePath @Arguments
    $exitCode = $LASTEXITCODE

    if ($script:logDirectory) {
        $logName = ($Activity -replace '[^\w\.\-]', '_') + '.log'
        $clean = ($output | Out-String) -replace "`0", ''
        Set-Content -LiteralPath (Join-Path $script:logDirectory $logName) -Value $clean -Encoding UTF8
    }

    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host "--- $Activity output ---"
        ($output | Out-String) -replace "`0", '' | Write-Host
        throw "$Activity failed with exit code $exitCode."
    }
}

<# Locates the newest Windows SDK build that has the packaging tools, preferring
   binaries matching the host architecture. #>
function Get-SdkToolDirectory {
    $root = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path $root)) {
        throw "Windows SDK not found at $root. Install the Windows 10/11 SDK."
    }

    $hostArch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $hostArch = 'arm64' }

    $candidates = Get-ChildItem $root -Directory |
        Where-Object { $_.Name -match '^10\.' } |
        Sort-Object { [version]$_.Name } -Descending

    foreach ($candidate in $candidates) {
        foreach ($arch in @($hostArch, 'x64', 'x86')) {
            $dir = Join-Path $candidate.FullName $arch
            if (Test-Path (Join-Path $dir 'makeappx.exe')) {
                return $dir
            }
        }
    }

    throw "No Windows SDK build under $root contains makeappx.exe."
}

function Get-ProjectVersion {
    [xml]$csproj = Get-Content -LiteralPath $projectPath -Raw
    $node = $csproj.SelectSingleNode('//PropertyGroup/Version')
    if (-not $node) {
        throw "No <Version> element found in $projectPath."
    }
    return $node.InnerText.Trim()
}

function Get-SigningCertificate {
    if ($CertificatePath) {
        if (-not (Test-Path $CertificatePath)) {
            throw "Certificate file not found: $CertificatePath"
        }
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $CertificatePath, $CertificatePassword)
    }

    if ($CertificateThumbprint) {
        $found = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $CertificateThumbprint.Replace(' ', '') }
        if (-not $found) {
            throw "No certificate with thumbprint $CertificateThumbprint in CurrentUser\My or LocalMachine\My."
        }
        return $found | Select-Object -First 1
    }

    return $null
}

# ---------------------------------------------------------------------------
# Resolve configuration
# ---------------------------------------------------------------------------

$sdkDir   = Get-SdkToolDirectory
$makeappx = Join-Path $sdkDir 'makeappx.exe'
$makepri  = Join-Path $sdkDir 'makepri.exe'
$signtool = Join-Path $sdkDir 'signtool.exe'

$version = Get-ProjectVersion
# MSIX versions are always four-part and the Store reserves the revision field.
$packageVersion = "$version.0"

[xml]$manifestTemplate = Get-Content -LiteralPath (Join-Path $packageDir 'Package.appxmanifest') -Raw
$namespaces = New-Object System.Xml.XmlNamespaceManager($manifestTemplate.NameTable)
$namespaces.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$identityNode = $manifestTemplate.SelectSingleNode('/f:Package/f:Identity', $namespaces)

$effectiveName      = $identityNode.GetAttribute('Name')
$effectivePublisher = $identityNode.GetAttribute('Publisher')

$certificate = $null
if ($Channel -eq 'Direct' -and -not $SkipSign) {
    $certificate = Get-SigningCertificate
    if (-not $certificate) {
        throw @'
Direct packages must be signed or Windows will refuse to install them.
Supply -CertificateThumbprint or -CertificatePath, or pass -SkipSign to build unsigned.
No certificate yet? Create one for local testing:
    pwsh -File build\New-DevCertificate.ps1
'@
    }
    # The package Publisher must equal the certificate subject exactly, so derive it
    # rather than trusting the two to be kept in sync by hand.
    $effectivePublisher = $certificate.SubjectName.Name
}

if ($IdentityName)  { $effectiveName = $IdentityName }
if ($Publisher)     { $effectivePublisher = $Publisher }

if ($Channel -eq 'Store' -and $effectivePublisher -like '*REPLACE-WITH-PARTNER-CENTER*') {
    throw @'
Package.appxmanifest still contains the placeholder Publisher.
Copy Name and Publisher from Partner Center (Product identity) into
build\Package\Package.appxmanifest before building a Store package.
'@
}

Write-Host "Channel        : $Channel"
Write-Host "Version        : $packageVersion"
Write-Host "Architectures  : $($Architectures -join ', ')"
Write-Host "Identity name  : $effectiveName"
Write-Host "Publisher      : $effectivePublisher"
if ($certificate) {
    Write-Host "Signing with   : $($certificate.Thumbprint)"
}
Write-Host "SDK tools      : $sdkDir"
Write-Host ''

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir  | Out-Null

$packagesDir = Join-Path $stagingDir 'packages'
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

$script:logDirectory = Join-Path $stagingDir 'logs'
New-Item -ItemType Directory -Force -Path $script:logDirectory | Out-Null

# Drop packages from earlier runs so a version bump cannot leave a stale bundle behind
# that then gets re-signed and reported as if it were part of this build. The dev
# certificate's public key is deliberately left in place.
Get-ChildItem $outputDir -File |
    Where-Object { $_.Extension -in '.msix', '.msixbundle', '.appinstaller' } |
    Remove-Item -Force

foreach ($arch in $Architectures) {
    Write-Host "=== $arch ==="
    $layout = Join-Path $stagingDir $arch

    Write-Host '  publishing...'
    $publishArguments = @(
        'publish', $projectPath,
        '--configuration', $Configuration,
        '--runtime', "win-$arch",
        '--self-contained', 'true',
        '--output', $layout,
        "-p:PublishReadyToRun=$($ReadyToRun.IsPresent.ToString().ToLowerInvariant())",
        '--nologo',
        '--verbosity', 'quiet'
    )
    Invoke-Tool -FilePath 'dotnet' -Arguments $publishArguments -Activity "dotnet publish ($arch)"

    # Symbols stay in bin/ for debugging; they have no place in a shipping package.
    Get-ChildItem $layout -Filter '*.pdb' -Recurse | Remove-Item -Force

    Write-Host '  staging package layout...'
    Copy-Item (Join-Path $packageDir 'Images') -Destination $layout -Recurse -Force

    $manifest = $manifestTemplate.Clone()
    $manifestNamespaces = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $manifestNamespaces.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $identity = $manifest.SelectSingleNode('/f:Package/f:Identity', $manifestNamespaces)
    $identity.SetAttribute('Name', $effectiveName)
    $identity.SetAttribute('Publisher', $effectivePublisher)
    $identity.SetAttribute('Version', $packageVersion)
    $identity.SetAttribute('ProcessorArchitecture', $arch)
    $manifest.Save((Join-Path $layout 'AppxManifest.xml'))

    Write-Host '  indexing resources...'
    $priConfig = Join-Path $stagingDir "priconfig-$arch.xml"
    Invoke-Tool -FilePath $makepri -Activity "makepri createconfig ($arch)" -Arguments @(
        'createconfig', '/cf', $priConfig, '/dq', 'en-US', '/pv', '10.0.0', '/o'
    )
    Invoke-Tool -FilePath $makepri -Activity "makepri new ($arch)" -Arguments @(
        'new',
        '/pr', $layout,
        '/cf', $priConfig,
        '/of', (Join-Path $layout 'resources.pri'),
        '/mn', (Join-Path $layout 'AppxManifest.xml'),
        '/o'
    )

    Write-Host '  packing...'
    $msixPath = Join-Path $packagesDir "AccessibilityMapper_${packageVersion}_$arch.msix"
    Invoke-Tool -FilePath $makeappx -Activity "makeappx pack ($arch)" -Arguments @(
        'pack', '/d', $layout, '/p', $msixPath, '/o'
    )

    $sizeMb = [Math]::Round((Get-Item $msixPath).Length / 1MB, 1)
    Write-Host "  -> $(Split-Path -Leaf $msixPath) ($sizeMb MB)"
}

# ---------------------------------------------------------------------------
# Bundle
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== bundle ==='
$bundleName = "AccessibilityMapper_$packageVersion.msixbundle"
$bundlePath = Join-Path $outputDir $bundleName
Invoke-Tool -FilePath $makeappx -Activity 'makeappx bundle' -Arguments @(
    'bundle', '/d', $packagesDir, '/p', $bundlePath, '/bv', $packageVersion, '/o'
)

# Keep the per-architecture packages too: useful for targeted sideloading and for
# reproducing a single-architecture install.
foreach ($msix in Get-ChildItem $packagesDir -Filter '*.msix') {
    Copy-Item $msix.FullName -Destination $outputDir -Force
}

# ---------------------------------------------------------------------------
# Sign and publish metadata
# ---------------------------------------------------------------------------

if ($Channel -eq 'Direct' -and -not $SkipSign) {
    Write-Host ''
    Write-Host '=== signing ==='

    $signArguments = @('sign', '/fd', 'SHA256')
    if ($CertificatePath) {
        $signArguments += @('/f', $CertificatePath)
        if ($CertificatePassword) { $signArguments += @('/p', $CertificatePassword) }
    }
    else {
        $signArguments += @('/sha1', $certificate.Thumbprint)
    }
    if ($TimestampUrl) {
        $signArguments += @('/tr', $TimestampUrl, '/td', 'SHA256')
    }

    $artifacts = Get-ChildItem $outputDir -File |
        Where-Object { $_.Extension -eq '.msix' -or $_.Extension -eq '.msixbundle' }
    foreach ($artifact in $artifacts) {
        Invoke-Tool -FilePath $signtool -Activity "signtool sign $($artifact.Name)" `
            -Arguments ($signArguments + @($artifact.FullName))
    }

    # A signature that does not chain to a trusted root is expected while testing with a
    # self-signed certificate, so report it rather than failing the build.
    Write-Host '  verifying...'
    & $signtool verify /pa /v $bundlePath
    if ($LASTEXITCODE -ne 0) {
        Write-Warning @"
The signature is present but does not chain to a trusted root on this machine.
That is normal for a self-signed test certificate. To install locally, trust it once
from an ELEVATED prompt:
    Import-Certificate -FilePath build\out\AccessibilityMapper-Dev.cer ``
        -CertStoreLocation Cert:\LocalMachine\TrustedPeople
A purchased code-signing certificate needs no such step on end-user machines.
"@
    }
}

if ($Channel -eq 'Direct') {
    $feedUrl = $UpdateUrl.TrimEnd('/')
    $appInstallerPath = Join-Path $outputDir 'AccessibilityMapper.appinstaller'

    # Written rather than templated so the version, identity and bundle filename can
    # never drift from the package that was just built.
    $appInstaller = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller
    xmlns="http://schemas.microsoft.com/appx/appinstaller/2018"
    Uri="$feedUrl/AccessibilityMapper.appinstaller"
    Version="$packageVersion">

  <MainBundle
    Name="$effectiveName"
    Publisher="$([System.Security.SecurityElement]::Escape($effectivePublisher))"
    Version="$packageVersion"
    Uri="$feedUrl/$bundleName" />

  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="8" ShowPrompt="true" />
    <AutomaticBackgroundTask />
  </UpdateSettings>

</AppInstaller>
"@
    Set-Content -LiteralPath $appInstallerPath -Value $appInstaller -Encoding UTF8
    Write-Host ''
    Write-Host "=== update feed ==="
    Write-Host "  -> $(Split-Path -Leaf $appInstallerPath) (publish alongside the bundle at $feedUrl/)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Artifacts:'
Get-ChildItem $outputDir -File | Sort-Object Name | ForEach-Object {
    "  {0,-52} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)
}

Write-Host ''
if ($Channel -eq 'Store') {
    Write-Host "Next: upload $bundleName to Partner Center. Do not sign it - the Store does that."
}
else {
    Write-Host "Next: publish the contents of $outputDir to $($UpdateUrl.TrimEnd('/'))/"
    Write-Host '      Users install from the .appinstaller URL and receive updates automatically.'
}

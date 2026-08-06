<#
.SYNOPSIS
    Creates a self-signed code-signing certificate for testing direct-distribution MSIX
    packages locally.

.DESCRIPTION
    Windows refuses to install an MSIX whose signature does not chain to a trusted root,
    so a package cannot be smoke-tested without *some* certificate. This creates one and
    exports the public half for trusting.

    THIS IS FOR LOCAL TESTING ONLY. A self-signed certificate has to be manually trusted
    on every machine, so it is useless for real distribution. Replace it with a purchased
    code-signing certificate before shipping - see docs/DISTRIBUTION.md. Microsoft signs
    Store submissions itself, so this is irrelevant to the Store channel.

    The subject must match the Publisher in the package identity exactly. Build-Packages.ps1
    reads the subject back off the certificate and rewrites the manifest to match, so the
    default below just needs to be stable, not meaningful.

.PARAMETER Subject
    Certificate subject / package Publisher. Must be a valid X.500 name.

.PARAMETER ValidYears
    Lifetime in years.

.EXAMPLE
    pwsh -File build/New-DevCertificate.ps1
    # then, from an elevated prompt, trust it:
    Import-Certificate -FilePath build\out\AccessibilityMapper-Dev.cer `
        -CertStoreLocation Cert:\LocalMachine\TrustedPeople
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=Druware Software Designs, O=Druware Software Designs, C=US',
    [int]$ValidYears = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$existing = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) }

if ($existing) {
    $certificate = $existing | Sort-Object NotAfter -Descending | Select-Object -First 1
    Write-Host "Reusing existing certificate $($certificate.Thumbprint)"
}
else {
    $certificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $Subject `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -FriendlyName 'Accessibility Mapper - MSIX sideload testing' `
        -NotAfter (Get-Date).AddYears($ValidYears) `
        -TextExtension @(
            '2.5.29.37={text}1.3.6.1.5.5.7.3.3',   # EKU: code signing
            '2.5.29.19={text}'                     # basic constraints: end entity
        )
    Write-Host "Created certificate $($certificate.Thumbprint)"
}

$cerPath = Join-Path $outputDir 'AccessibilityMapper-Dev.cer'
Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null

Write-Host ''
Write-Host "Subject     : $($certificate.Subject)"
Write-Host "Thumbprint  : $($certificate.Thumbprint)"
Write-Host "Expires     : $($certificate.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "Public key  : $cerPath"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Trust it (run this from an ELEVATED PowerShell prompt):'
Write-Host "       Import-Certificate -FilePath `"$cerPath`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
Write-Host '  2. Build a signed package:'
Write-Host "       pwsh -File build\Build-Packages.ps1 -Channel Direct -CertificateThumbprint $($certificate.Thumbprint)"

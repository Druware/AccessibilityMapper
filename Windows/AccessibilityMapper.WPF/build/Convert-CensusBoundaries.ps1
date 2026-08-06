#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the bundled boundary dataset from U.S. Census cartographic boundary files.

.DESCRIPTION
    Downloads the three national 1:500,000 cartographic boundary shapefiles (place, county,
    state), converts them to the compact artifact the app ships as
    src/AccessibilityMapper.App/Assets/Boundaries/boundaries.bin, and reports the result.

    The artifact is committed, so this script only needs to run when moving to a new Census
    vintage. Contributors and CI never need it, and never need GDAL/ogr2ogr installed:
    build/tools/CensusBoundaryConverter reads the shapefiles directly.

    Census cartographic boundary files are a work of the U.S. Government and are in the
    public domain. There is no rate limit, no API key, and no attribution requirement -
    though the About dialog credits the Census Bureau anyway.

.PARAMETER Vintage
    Census vintage year to download. Defaults to 2025.

.PARAMETER WorkDir
    Where to download and unzip. Defaults to a temp folder that is removed afterwards.

.PARAMETER KeepDownloads
    Leave the downloaded zips in place so a re-run does not re-download ~36 MB.

.EXAMPLE
    pwsh -File build/Convert-CensusBoundaries.ps1

.EXAMPLE
    pwsh -File build/Convert-CensusBoundaries.ps1 -Vintage 2026 -KeepDownloads
#>
[CmdletBinding()]
param(
    [int]$Vintage = 2025,
    [string]$WorkDir,
    [switch]$KeepDownloads
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$converter = Join-Path $PSScriptRoot 'tools/CensusBoundaryConverter/CensusBoundaryConverter.csproj'
$output = Join-Path $repoRoot 'src/AccessibilityMapper.App/Assets/Boundaries/boundaries.bin'

if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "census-boundaries-$Vintage"
}
$cleanUp = -not $KeepDownloads -and -not $PSBoundParameters.ContainsKey('WorkDir')

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "The .NET SDK is required (dotnet not found)."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$layers = @('place', 'county', 'state')
$baseUrl = "https://www2.census.gov/geo/tiger/GENZ$Vintage/shp"

Write-Host "Census cartographic boundary files, vintage $Vintage" -ForegroundColor Cyan

foreach ($layer in $layers) {
    $name = "cb_${Vintage}_us_${layer}_500k.zip"
    $zip = Join-Path $WorkDir $name
    $expanded = Join-Path $WorkDir $layer

    if (Test-Path $zip) {
        Write-Host "  $name (cached)"
    }
    else {
        Write-Host "  $name downloading..."
        try {
            Invoke-WebRequest -Uri "$baseUrl/$name" -OutFile $zip -TimeoutSec 300 -UseBasicParsing
        }
        catch {
            throw "Failed to download $baseUrl/$name - $($_.Exception.Message)"
        }
    }

    if (Test-Path $expanded) { Remove-Item $expanded -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $expanded -Force
}

Write-Host "Converting..." -ForegroundColor Cyan
& dotnet run --project $converter -c Release --nodeReuse:false -- $WorkDir $output $Vintage
if ($LASTEXITCODE -ne 0) {
    throw "Converter failed with exit code $LASTEXITCODE."
}

if ($cleanUp) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Done. Commit the updated artifact:" -ForegroundColor Green
Write-Host "  $output"

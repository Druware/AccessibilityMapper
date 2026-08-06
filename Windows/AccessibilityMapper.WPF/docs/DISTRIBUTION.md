# Distribution

Accessibility Mapper ships as an **MSIX package** through two channels:

| Channel | Artifact | Signed by |
|---|---|---|
| Microsoft Store | `AccessibilityMapper_<version>.msixbundle` uploaded to Partner Center | Microsoft, during ingestion |
| Direct download | the same bundle plus `AccessibilityMapper.appinstaller` hosted on your own site | you, with your code-signing certificate |

Both channels build from one manifest and one script, so the two downloads are the same
application. Both publish **self-contained**: neither requires the end user to install a
.NET runtime.

---

## Prerequisites

- .NET 10 SDK
- Windows 10/11 SDK — supplies `makeappx.exe`, `makepri.exe` and `signtool.exe`.
  The build script auto-detects the newest installed SDK under
  `C:\Program Files (x86)\Windows Kits\10\bin`.

Nothing else. There is no dependency on Visual Studio or on a `.wapproj`.

---

## Layout

```
build/
  Build-Packages.ps1        build both channels
  New-DevCertificate.ps1    self-signed certificate for local install testing
  New-AppIcons.ps1          regenerate all icon artwork from its vector definition
  Package/
    Package.appxmanifest    package identity, capabilities, tile definitions
    Images/                 Store logos (committed; regenerate with New-AppIcons.ps1)
  out/                      build artifacts (git-ignored)
  staging/                  intermediate package layouts and tool logs (git-ignored)
```

---

## Versioning

`<Version>` in `src/AccessibilityMapper.App/AccessibilityMapper.App.csproj` is the single
source of truth. `Build-Packages.ps1` reads it and appends `.0` to form the four-part MSIX
version, because **the Store reserves the revision field and rejects a non-zero value**.

To ship an update, bump `<Version>` (and `<AssemblyVersion>`/`<FileVersion>` to match) and
rebuild. The Store also rejects any upload whose version is not higher than the last one
accepted.

> Known gap: the About dialog's version string is hardcoded to `Version 1.0 (1)` because
> `docs/CONVERSION-SPEC.md` §9.3 pins that text verbatim. It will not track `<Version>`
> until that text is allowed to change.

---

## Microsoft Store

### One-time setup

1. In [Partner Center](https://partner.microsoft.com/dashboard), reserve the app name.
2. Open **Product identity** and copy the two values shown there into
   `build/Package/Package.appxmanifest`:

   | Partner Center field | Manifest attribute |
   |---|---|
   | Package/Identity/Name | `<Identity Name="...">` |
   | Package/Identity/Publisher | `<Identity Publisher="CN=...">` |

   They must match byte for byte. The manifest currently holds
   `CN=REPLACE-WITH-PARTNER-CENTER-PUBLISHER-ID`, and the build refuses to produce a Store
   package until you replace it.

3. Fill in the submission fields Partner Center requires. Two apply specifically here:
   - **Privacy policy URL** — mandatory, because the app makes network requests
     (geocoding, boundary lookups, map tiles).
   - **runFullTrust justification** — expected and routine for a packaged desktop app;
     state that it is a Win32/WPF application.

### Each release

```powershell
pwsh -File build\Build-Packages.ps1 -Channel Store
```

Upload `build\out\AccessibilityMapper_<version>.msixbundle`.

**Do not sign it.** The Store re-signs with its own certificate, and a pre-existing
signature causes the upload to be rejected.

---

## Direct distribution

### Signing

Windows will not install an MSIX whose signature does not chain to a trusted root, so
direct packages must be signed.

**For real distribution**, buy a code-signing certificate (an OV certificate is
sufficient; EV additionally avoids SmartScreen reputation warmup). Then either import it
into `Cert:\CurrentUser\My` and pass its thumbprint, or point the build at the `.pfx`:

```powershell
pwsh -File build\Build-Packages.ps1 -Channel Direct `
    -CertificatePath C:\secure\codesign.pfx -CertificatePassword $env:CERT_PASSWORD `
    -UpdateUrl https://druware.com/accessibilitymapper
```

The script reads the certificate's subject and rewrites the package `Publisher` to match,
so the two can never drift out of sync.

**For local testing only**, generate a self-signed certificate:

```powershell
pwsh -File build\New-DevCertificate.ps1
# then, from an ELEVATED prompt, trust it on this machine:
Import-Certificate -FilePath build\out\AccessibilityMapper-Dev.cer `
    -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

Until that import is done, `signtool verify` reports an untrusted root. The build treats
that as a warning, not a failure, because it is the expected state for a test certificate.
A self-signed certificate has to be trusted manually on every machine, so it is only ever
useful for smoke-testing an install.

### Publishing

```powershell
pwsh -File build\Build-Packages.ps1 -Channel Direct `
    -CertificateThumbprint <thumbprint> -UpdateUrl https://druware.com/accessibilitymapper
```

Upload everything in `build\out\` to that URL, keeping the filenames. Serve
`.appinstaller` as `application/appinstaller` and `.msixbundle` as
`application/msix-bundle`, or Windows may download instead of install.

Users install by opening the `.appinstaller` URL. Windows then checks that URL on launch
(at most every 8 hours) and in the background, and updates itself — so shipping an update
is just rebuilding with a higher `<Version>` and re-uploading.

The per-architecture `.msix` files are also emitted, for targeted sideloading or for
`Add-AppxPackage` in a managed deployment.

---

## Architectures

`x64` and `arm64` by default, combined into one bundle; Windows installs the matching one.
Narrow it with `-Architectures x64` for a faster loop while iterating.

**`x86` is supported but not built by default.** Windows 11 has no x86 edition, so it only
serves 32-bit Windows 10 holdouts and is not worth a third of the bundle size for every
release. Build it when you want it:

```powershell
pwsh -Command "./build/Build-Packages.ps1 -Architectures x64,arm64,x86"
```

`-Command`, not `-File`: under `-File` every argument arrives as a literal string, so
`x64,arm64,x86` reaches the script as one value and fails the `ValidateSet`. The `-File`
form elsewhere in this document is fine because those parameters are scalars. From an
interactive `pwsh` prompt, calling the script directly works either way.

All three are listed in `<RuntimeIdentifiers>`, so `dotnet publish -r win-x86` also works
directly without editing the project. **Any publish that names a runtime is self-contained
automatically**: the csproj sets `SelfContained` whenever a `RuntimeIdentifier` is present,
so no caller has to remember the flag. A plain `dotnet build` with no runtime stays
framework-dependent, which keeps the development loop fast.

Expect roughly 150-170 MB per architecture before compression: a self-contained WPF app
plus the 23 MB bundled boundary dataset.

## Faster cold start

`-ReadyToRun` precompiles to native code. It roughly doubles the package size in exchange
for noticeably quicker launch. Off by default.

---

## The WebView2 dependency

The map is a WebView2 control, so the **Evergreen WebView2 Runtime** must be present. It
is preinstalled on Windows 11 and arrives on Windows 10 with Microsoft Edge, but it can be
absent or removed.

Two things handle this:

- `App.OnStartup` checks for the runtime and, if missing, explains the problem and offers
  the download rather than crashing. A launch crash is an automatic Store certification
  failure.
- `MapControl` points WebView2's user-data folder at `%LOCALAPPDATA%\AccessibilityMapper\WebView2`.
  This is **required** for MSIX: the default location is beside the executable, and an
  MSIX install directory is read-only, so the default would fail on every packaged launch.

---

## Not included

Deliberate omissions, each a small piece of work if you want it:

- **`.accmap` file associations.** Declaring `uap:FileTypeAssociation` in the manifest
  would make double-clicking a document open the app, but the app would also need to
  handle a file path on the command line and respond to packaged file activation. Without
  that second half the association would look broken, so neither half is present.
- **Symbol upload.** `.pdb` files are stripped from the package. To get readable crash
  stacks from Partner Center telemetry, produce an `.appxsym` and upload it with the
  bundle.
- **A classic `setup.exe`.** MSIX covers install, uninstall and update; an MSI or Inno
  Setup installer would only be needed to support Windows versions below 10.0.17763 or to
  install machine-wide for all users.

## Before a public launch

The app geocodes and fetches boundary polygons from **Nominatim**, whose usage policy caps
request rates and forbids heavy use by distributed clients. A Store listing can generate
far more traffic than a personal build. Plan on either a self-hosted Nominatim instance or
a commercial geocoding provider before the listing goes live.

# Every packaged runtime file must match a declared build or vendor input.
# Root LICENSE applies to this module; vendor files retain their own terms.
Set-StrictMode -Version Latest

function Get-GufoRelativePath([string]$Root, [string]$Path) {
  $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "File outside package directory: $Path"
  }
  $full.Substring($prefix.Length).Replace('\', '/')
}

function Get-GufoVcpkgOwners([string]$Vcpkg) {
  $owners = @{}
  $allowed = @('curl', 'icu', 'libjpeg-turbo', 'libpng', 'libspng', 'libwebp', 'openssl', 'zlib')
  foreach ($list in Get-ChildItem (Join-Path $Vcpkg 'installed/vcpkg/info/*_x64-windows.list')) {
    if ($list.Name -notmatch '^([a-z0-9-]+)_(.+)_x64-windows\.list$') { continue }
    $port = $matches[1]
    $version = $matches[2]
    if ($allowed -notcontains $port) { continue }
    foreach ($line in Get-Content -LiteralPath $list.FullName) {
      $entry = $line.Trim().Replace('\', '/')
      if ($entry -notmatch '^x64-windows/bin/([^/]+\.dll)$') { continue }
      $name = $matches[1]
      if ($owners.ContainsKey($name)) { throw "Duplicate vcpkg owner: $name" }
      $owners[$name] = @{ port = $port; version = $version }
    }
  }
  $owners
}

function Get-GufoPackageProvenance {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$Bin,
    [Parameter(Mandatory)] [string]$Build,
    [Parameter(Mandatory)] [string]$Rocm,
    [Parameter(Mandatory)] [string]$Vcpkg,
    [Parameter(Mandatory)] [hashtable]$MicrosoftSources,
    [Parameter(Mandatory)] [string]$Repository,
    [Parameter(Mandatory)] [string]$Revision,
    [Parameter(Mandatory)] [string]$VcpkgRevision,
    [scriptblock]$ReadSignature = {
      param($Path)
      $signature = Get-AuthenticodeSignature -LiteralPath $Path
      $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
      $thumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null }
      @{ status = [string]$signature.Status; subject = $subject; thumbprint = $thumbprint }
    }
  )
  $expectedVcpkg = '20ceb8adbf0504d4b0d5e4058a32f9d4fc896391'
  if ($VcpkgRevision -ne $expectedVcpkg) { throw 'Unqualified vcpkg revision; review the provenance policy before updating it' }
  if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'A complete public source commit is required' }
  if ($Repository -ne 'https://github.com/DanisJiang/gufo-windows') { throw 'Unexpected Gufo source repository' }
  if ((Get-Content (Join-Path $Rocm '.info/version') -TotalCount 1).Trim() -ne '10.0.0') {
    throw 'Unqualified TheRock version; review the official download and digest before updating it'
  }
  $owners = Get-GufoVcpkgOwners $Vcpkg
  $records = [Collections.Generic.List[object]]::new()
  foreach ($file in Get-ChildItem -LiteralPath $Bin -Recurse -File | Sort-Object FullName) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in package: $($file.FullName)" }
    $relative = Get-GufoRelativePath $Bin $file.FullName
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $source = $null
    $origin = $null
    if ($relative -eq 'gufo.exe') {
      $source = Join-Path $Build 'gufo.exe'
      $origin = @{ kind = 'public-source-build'; repository = $Repository; commit = $Revision; license = 'MIT (Gufo source); platform runtimes retain their terms' }
    } elseif ($MicrosoftSources.ContainsKey($relative)) {
      if ($relative -notmatch '^(msvcp140[^/]*|vcruntime140[^/]*|libomp140\.x86_64)\.dll$') {
        throw "Unexpected Microsoft runtime filename: $relative"
      }
      $source = $MicrosoftSources[$relative]
      $origin = @{ kind = 'official-microsoft-runtime'; source = 'Visual Studio runtime files on the GitHub-hosted runner'; terms = 'Microsoft runtime terms; STL/LLVM source licenses also apply where relevant' }
    } else {
      $candidate = Join-Path (Join-Path $Rocm 'bin') $relative
      if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
          (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -eq $hash) {
        $source = $candidate
        $origin = @{ kind = 'official-amd-therock'; version = '10.0.0'; url = 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx1151-10.0.0.tar.gz'; archive_sha256 = '1293927b06b3b8d4bd7e0265823fb998bc9e0d83c68f33dcfa5d32663b30ce38'; file = "bin/$relative"; terms = 'Component-specific licenses; Windows HIP includes proprietary PAL/interop components' }
      } elseif (-not $relative.Contains('/') -and $owners.ContainsKey($relative)) {
        $owner = $owners[$relative]
        $source = Join-Path (Join-Path $Vcpkg 'installed/x64-windows/bin') $relative
        $origin = @{ kind = 'public-source-build'; builder = 'microsoft/vcpkg'; commit = $VcpkgRevision; port = $owner.port; version = $owner.version; recipe = "https://github.com/microsoft/vcpkg/blob/$VcpkgRevision/ports/$($owner.port)/portfile.cmake"; license = "licenses/vcpkg/$($owner.port)/copyright" }
      }
    }
    if (-not $origin -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Unclassified runtime file; refusing to package it: $relative"
    }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
      throw "Runtime file differs from its declared input: $relative"
    }
    $signature = if ($file.Extension -in @('.exe', '.dll')) { & $ReadSignature $file.FullName } else { $null }
    if ($origin.kind -eq 'official-microsoft-runtime' -and
        ($signature.status -ne 'Valid' -or $signature.subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)')) {
      throw "Microsoft runtime lacks a valid Microsoft signature: $relative"
    }
    $records.Add([ordered]@{ path = "bin/$relative"; bytes = $file.Length; sha256 = $hash; origin = $origin; authenticode = $signature })
  }
  if (-not ($records | Where-Object { $_.path -eq 'bin/gufo.exe' })) { throw 'Package has no gufo.exe' }
  [ordered]@{
    schema_version = 1
    source = @{ repository = $Repository; commit = $Revision }
    builder = @{ repository = $env:GITHUB_REPOSITORY; run_id = $env:GITHUB_RUN_ID; runner_image = $env:ImageVersion }
    scope = 'Binary origin and integrity verification; not a proof of absence of malware or vulnerabilities'
    files = @($records.ToArray())
  }
}

Export-ModuleMember -Function Get-GufoPackageProvenance

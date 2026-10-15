$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'provenance.psm1') -Force
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("gufo-provenance-" + [guid]::NewGuid())
try {
  $bin = Join-Path $temporary 'stage/bin'
  $build = Join-Path $temporary 'build'
  $rocm = Join-Path $temporary 'rocm'
  $vcpkg = Join-Path $temporary 'vcpkg'
  $microsoft = Join-Path $temporary 'microsoft'
  foreach ($path in @($bin, "$bin/rocblas/library", $build, "$rocm/bin/rocblas/library", "$rocm/.info", "$vcpkg/installed/x64-windows/bin", "$vcpkg/installed/vcpkg/info", $microsoft)) {
    New-Item -ItemType Directory -Force $path | Out-Null
  }
  Set-Content "$rocm/.info/version" '10.0.0'
  Set-Content "$build/gufo.exe" 'public Gufo build fixture'
  Set-Content "$rocm/bin/amdhip64_7.dll" 'official AMD input fixture'
  Set-Content "$rocm/bin/rocblas/library/gfx1151.hsaco" 'official AMD kernel fixture'
  Set-Content "$vcpkg/installed/x64-windows/bin/zlib1.dll" 'public zlib build fixture'
  Set-Content "$vcpkg/installed/vcpkg/info/zlib_1.3.2_x64-windows.list" 'x64-windows/bin/zlib1.dll'
  Set-Content "$microsoft/vcruntime140.dll" 'Microsoft input fixture'
  Copy-Item "$build/gufo.exe", "$rocm/bin/amdhip64_7.dll", "$vcpkg/installed/x64-windows/bin/zlib1.dll", "$microsoft/vcruntime140.dll" $bin
  Copy-Item "$rocm/bin/rocblas/library/gfx1151.hsaco" "$bin/rocblas/library"
  $parameters = @{
    Bin = $bin; Build = $build; Rocm = $rocm; Vcpkg = $vcpkg
    MicrosoftSources = @{ 'vcruntime140.dll' = "$microsoft/vcruntime140.dll" }
    Repository = 'https://github.com/DanisJiang/gufo-windows'
    Revision = '1111111111111111111111111111111111111111'
    VcpkgRevision = '20ceb8adbf0504d4b0d5e4058a32f9d4fc896391'
    ReadSignature = { param($Path) @{ status = 'Valid'; subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; thumbprint = 'fixture' } }
  }
  $manifest = Get-GufoPackageProvenance @parameters
  if ($manifest.files.Count -ne 5) { throw 'Declared runtime inputs were not all classified' }
  $kinds = @($manifest.files | ForEach-Object { $_.origin.kind } | Sort-Object -Unique)
  if ($kinds.Count -ne 3) { throw 'Missing public-source, AMD or Microsoft origin' }
  function Expect-Rejected([string]$Reason) {
    try { $null = Get-GufoPackageProvenance @parameters } catch {
      if ($_.Exception.Message -notmatch $Reason) { throw }
      return
    }
    throw "Expected rejection: $Reason"
  }
  Set-Content "$bin/unknown.dll" 'undeclared executable payload'
  Expect-Rejected 'Unclassified runtime file'
  Remove-Item "$bin/unknown.dll"
  Add-Content "$bin/gufo.exe" 'altered Gufo build'
  Expect-Rejected 'differs from its declared input'
  Copy-Item "$build/gufo.exe" $bin -Force
  Add-Content "$bin/amdhip64_7.dll" 'altered after copying'
  Expect-Rejected 'Unclassified runtime file|differs from its declared input'
  Copy-Item "$rocm/bin/amdhip64_7.dll" $bin -Force
  Add-Content "$bin/rocblas/library/gfx1151.hsaco" 'altered kernel'
  Expect-Rejected 'Unclassified runtime file|differs from its declared input'
  Copy-Item "$rocm/bin/rocblas/library/gfx1151.hsaco" "$bin/rocblas/library" -Force
  Add-Content "$bin/zlib1.dll" 'altered public dependency'
  Expect-Rejected 'differs from its declared input'
  Copy-Item "$vcpkg/installed/x64-windows/bin/zlib1.dll" $bin -Force
  Remove-Item "$vcpkg/installed/vcpkg/info/zlib_1.3.2_x64-windows.list"
  Expect-Rejected 'Unclassified runtime file'
  Set-Content "$vcpkg/installed/vcpkg/info/zlib_1.3.2_x64-windows.list" 'x64-windows/bin/zlib1.dll'
  $parameters.ReadSignature = { param($Path) @{ status = 'NotSigned'; subject = $null } }
  Expect-Rejected 'lacks a valid Microsoft signature'
  $parameters.ReadSignature = { param($Path) @{ status = 'Valid'; subject = 'CN=Other Publisher, O=Other Publisher, C=US' } }
  Expect-Rejected 'lacks a valid Microsoft signature'
  Write-Host 'PASS: public and vendor inputs classified; unknown files, tampering, unowned DLLs and invalid publisher signatures rejected'
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
if ($env:OS -eq 'Windows_NT') {
  $native = Get-GufoMicrosoftRuntimeSources
  Write-Host ("PASS: native Microsoft runtime signatures valid: " + (($native.Keys | Sort-Object) -join ', '))
}

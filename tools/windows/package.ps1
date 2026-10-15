# Packs the release build into a prebuilt zip for people who do not build:
#   gufo-windows-<version>\
#     start.cmd                    the launcher (number keys)
#     bin\gufo.exe + DLLs          ROCm runtime (gfx1151 kernels), vcpkg libraries,
#                                  and the Visual C++ / OpenMP runtimes (app-local)
#     tools\windows\launcher.ps1, inventory.ps1
#     README.txt, LICENSE, THIRD-PARTY.txt
#
#   powershell -ExecutionPolicy Bypass -File tools\windows\package.ps1 [-Version 2026-10-03] [-Out dist]
param(
  [string]$Version = (Get-Date -Format "yyyy-MM-dd"),
  [string]$Out = "",
  [string]$Vcpkg = "C:\vcpkg",
  [string]$Rocm = "C:\TheRock\build"
)
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'provenance.psm1') -Force
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$build = Join-Path $root "build\release"
if (-not $Out) { $Out = Join-Path $root "dist" }
if (-not (Test-Path (Join-Path $build "gufo.exe"))) { throw "build first: tools\windows\build.ps1" }

$name = "gufo-windows-$Version"
$stage = Join-Path $Out $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$bin = Join-Path $stage "bin"
New-Item -ItemType Directory -Force $bin, (Join-Path $stage "tools\windows") | Out-Null

Copy-Item (Join-Path $build "gufo.exe") $bin
Get-ChildItem (Join-Path $build "*.dll") | Copy-Item -Destination $bin
foreach ($dir in "rocblas", "hipblaslt") {
  if (Test-Path (Join-Path $build $dir)) { Copy-Item (Join-Path $build $dir) -Destination $bin -Recurse }
}

# Visual C++ runtime (app-local deployment of the redistributable files) and
# the LLVM OpenMP runtime the ROCm BLAS libraries import.
$redist = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio", "$env:ProgramFiles\Microsoft Visual Studio" -Recurse -Directory `
  -Filter "Microsoft.VC14*.CRT" -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match "\\Redist\\MSVC\\[0-9.]+\\x64\\" -and $_.FullName -notmatch "onecore" } |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $redist) { throw "Visual C++ redistributable files not found (Visual Studio Build Tools)" }
$microsoftSources = @{}
Get-ChildItem (Join-Path $redist.FullName "*.dll") | Where-Object { $_.Name -match "^(msvcp140|vcruntime140)" } | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $bin
  $microsoftSources[$_.Name] = $_.FullName
}
$omp = Get-ChildItem (Join-Path (Split-Path $redist.FullName) "Microsoft.VC14*.OpenMP.LLVM\libomp140.x86_64.dll") -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $omp) { $omp = Get-Item "$env:SystemRoot\System32\libomp140.x86_64.dll" -ErrorAction SilentlyContinue }
if (-not $omp) { throw "libomp140.x86_64.dll not found (install the Visual C++ redistributable)" }
Copy-Item $omp.FullName $bin
$microsoftSources[$omp.Name] = $omp.FullName

Copy-Item (Join-Path $root "start.cmd") $stage
Copy-Item (Join-Path $root "tools\windows\launcher.ps1"), (Join-Path $root "tools\windows\inventory.ps1") (Join-Path $stage "tools\windows")
Copy-Item (Join-Path $root "LICENSE") $stage
Copy-Item (Join-Path $root "NOTICE"), (Join-Path $root "THIRD_PARTY_NOTICES.md") $stage
Copy-Item (Join-Path $root "licenses") $stage -Recurse
foreach ($copyright in Get-ChildItem (Join-Path $Vcpkg "installed\x64-windows\share\*\copyright")) {
  $port = Split-Path (Split-Path $copyright.FullName) -Leaf
  $destination = Join-Path $stage "licenses\vcpkg\$port"
  New-Item -ItemType Directory -Force $destination | Out-Null
  Copy-Item $copyright.FullName $destination
}
Copy-Item (Join-Path $root "tools\windows\prebuilt\README.txt"), (Join-Path $root "tools\windows\prebuilt\THIRD-PARTY.txt") $stage
$revision = (& git -C $root rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $revision) { throw 'Git source revision is required for package provenance' }
if (& git -C $root status --porcelain --untracked-files=no) { throw 'Commit source changes before packaging so the build is traceable' }
$commit = $revision.Substring(0, 7)
$source = (& git -C $root remote get-url origin) -replace '\.git$', ''
Add-Content (Join-Path $stage "README.txt") "`r`nBuilt from $source commit $commit ($Version)."
$vcpkgRevision = (& git -C $Vcpkg rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Git vcpkg revision is required for package provenance' }
$provenance = Get-GufoPackageProvenance -Bin $bin -Build $build -Rocm $Rocm -Vcpkg $Vcpkg `
  -MicrosoftSources $microsoftSources -Repository $source.Trim() -Revision $revision.Trim() -VcpkgRevision $vcpkgRevision
$provenance['source_files'] = @('start.cmd', 'tools/windows/launcher.ps1', 'tools/windows/inventory.ps1') | ForEach-Object {
  $inputPath = Join-Path $root $_
  $outputPath = Join-Path $stage $_
  $digest = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $digest) { throw "Packaged script differs from source: $_" }
  @{ path = $_; sha256 = $digest; source_commit = $revision.Trim() }
}
$provenance | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 (Join-Path $stage 'PROVENANCE.json')
$provenance.files | ForEach-Object { "$($_.sha256)  $($_.path)" } | Set-Content -Encoding UTF8 (Join-Path $stage 'SHA256SUMS.txt')

$zip = Join-Path $Out "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
# Windows' bsdtar writes zip; a GNU tar earlier on PATH (Git) does not.
& (Join-Path $env:SystemRoot "System32\tar.exe") -a -c -f $zip -C $Out $name
if ($LASTEXITCODE -ne 0) { throw "zip failed" }
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$zipHash  $name.zip" | Set-Content -Encoding UTF8 "$zip.sha256"
Copy-Item (Join-Path $stage 'PROVENANCE.json') (Join-Path $Out "$name.provenance.json")
"{0}  {1:N0} MB" -f $zip, ((Get-Item $zip).Length / 1MB)

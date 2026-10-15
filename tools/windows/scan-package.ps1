param(
  [Parameter(Mandatory)] [string]$Path,
  [Parameter(Mandatory)] [string]$Report
)
$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $Path).Path
$result = [ordered]@{
  scanner = 'Microsoft Defender'
  scope = 'Custom scan of the staged Windows package; not a guarantee of absence of malware'
  status = 'not_available'
  started_utc = (Get-Date).ToUniversalTime().ToString('o')
}
try {
  if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
    $result.reason = 'Defender cmdlets are not installed on this runner'
    return
  }
  try { $status = Get-MpComputerStatus } catch {
    $result.reason = "Defender status unavailable: $($_.Exception.Message)"
    return
  }
  if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled) {
    $result.reason = 'Defender is not enabled on this runner; no scan was performed'
    return
  }
  $scanner = Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $scanner) { $scanner = Get-Item "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -ErrorAction SilentlyContinue }
  if (-not $scanner) { $result.reason = 'Official Defender scanner executable unavailable'; return }
  $signature = Get-AuthenticodeSignature -LiteralPath $scanner.FullName
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
    throw 'Defender scanner does not have a valid Microsoft signature'
  }
  $result.signature_version = [string]$status.AntivirusSignatureVersion
  $result.signature_updated_utc = $status.AntivirusSignatureLastUpdated.ToUniversalTime().ToString('o')
  # Do not silently remediate a detection and then publish the original zip.
  $result.log = (& $scanner.FullName -Scan -ScanType 3 -File $target -DisableRemediation 2>&1 | Out-String)
  $result.exit_code = $LASTEXITCODE
  if ($LASTEXITCODE -ne 0) {
    $result.status = 'scan_failed_or_detected'
    throw 'Defender reported a detection or scan error; refusing to publish'
  }
  $result.status = 'completed_no_detections'
} catch {
  if ($result.status -ne 'scan_failed_or_detected') { $result.status = 'scan_error' }
  $result.reason = $_.Exception.Message
  throw
} finally {
  $result.finished_utc = (Get-Date).ToUniversalTime().ToString('o')
  $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Report -Encoding UTF8
  Write-Host "Defender package scan: $($result.status)"
  if ($result.Contains('reason')) { Write-Host $result.reason }
}

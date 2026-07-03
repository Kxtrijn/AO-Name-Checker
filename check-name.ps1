param(
  [Parameter(Mandatory=$false, Position=0, ValueFromPipeline=$true)]
  [string[]]$Names,

  [Alias("f")]
  [string]$File,

  [Alias("t")]
  [int]$Threads = 2,

  [Alias("o")]
  [string]$Output = "",

  [Alias("s")]
  [ValidateSet("all", "us", "eu", "asia")]
  [string]$Server = "all",

  [Alias("h")]
  [switch]$Help
)

# ---- Help ----

if ($Help) {
  Write-Host @"

Albion Online Name Availability Checker

Checks if names are taken on Albion Online servers (US, EU, Asia).

USAGE:
  .\$($MyInvocation.MyCommand.Name) [-Names <names>] [-File <path>] [-Server <server>] [-Threads <n>] [-Output <file>]

PARAMETERS:
  -Names       One or more names to check (space or comma separated).
  -File        Path to a text file with one name per line.
  -Server      Server(s) to check: us, eu, asia, or all (default).
  -Threads     Number of concurrent API calls (default: 2).
  -Output      Save results to a log file.
  -Help        Show this help.

EXAMPLES:
  .\$($MyInvocation.MyCommand.Name) -Names Hero, Test
  .\$($MyInvocation.MyCommand.Name) -File names.txt -Server all -Threads 4
  .\$($MyInvocation.MyCommand.Name) -Names Aaa, Bbb -Server eu -Output results.log

STATUS CODES:
  AVAILABLE   Name is free (server returned < 10 results, no exact match).
  TAKEN       Name is in use (exact match found, guild shown if any).
  UNSURE      Name might exist (server hit 10-result limit, match could be buried).

"@
  exit
}

# ---- Main ----

$servers = @{
  us   = "https://gameinfo.albiononline.com/api/gameinfo"
  eu   = "https://gameinfo-ams.albiononline.com/api/gameinfo"
  asia = "https://gameinfo-sgp.albiononline.com/api/gameinfo"
}

$activeServers = if ($Server -eq "all") { $servers.Keys } else { @($Server) }

if ($Output) {
  $Output = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $Output))
  Start-Transcript -Path $Output -Force | Out-Null
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$allNames = @()

if ($File) {
  if (-not (Test-Path -LiteralPath $File)) {
    Write-Host "File not found: $File" -ForegroundColor Red
    if ($Output) { Stop-Transcript | Out-Null }
    exit 1
  }
  $allNames += Get-Content -LiteralPath $File | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() }
}

if ($Names) {
  $allNames += $Names
}

if ($allNames.Count -eq 0) {
  Write-Host "Usage:" -ForegroundColor Yellow
  Write-Host "  .\check-name.ps1 -Names Kat" -ForegroundColor Cyan
  Write-Host "  .\check-name.ps1 -Names Kat, Hero -Server eu" -ForegroundColor Cyan
  Write-Host "  .\check-name.ps1 -File names.txt -Server all" -ForegroundColor Cyan
  Write-Host "  .\check-name.ps1 -File names.txt -Output results.log" -ForegroundColor Cyan
  Write-Host "  .\check-name.ps1 -File names.txt -Threads 20" -ForegroundColor Cyan
  Write-Host "Servers: us (Americas), eu (Europe), asia, all" -ForegroundColor Cyan
  if ($Output) { Stop-Transcript | Out-Null }
  exit
}

$total = $allNames.Count
$results = @()

Write-Host "Checking $total name(s) on [$($activeServers -join ', ')] ($Threads threads)..." -ForegroundColor Cyan
Write-Host ""

$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
$runspacePool.Open()
$jobs = @()

function Show-Result {
  param($r)
  $color = switch ($r.Status) {
    "AVAILABLE" { [ConsoleColor]::Green }
    "TAKEN"     { [ConsoleColor]::Red }
    "UNSURE"    { [ConsoleColor]::DarkYellow }
    "ERROR"     { [ConsoleColor]::Yellow }
    default     { [ConsoleColor]::Gray }
  }
  Write-Host ("  {0,-20} {1,-50}" -f $r.Name, $r.Guild) -ForegroundColor $color
}

$scriptText = @'
param($n, $serverList)
try {
  $lower = $n.ToLower()
  $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
  $bases = @{ us = "https://gameinfo.albiononline.com/api/gameinfo"; eu = "https://gameinfo-ams.albiononline.com/api/gameinfo"; asia = "https://gameinfo-sgp.albiononline.com/api/gameinfo" }
  $anyTaken = $false; $anyLimit = $false; $serverDetails = @()
  foreach ($srv in $serverList) {
    $base = $bases[$srv]
    $url = "$base/search?q=$([System.Uri]::EscapeDataString($n))"
    $found = $false; $limitHit = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      try {
        Start-Sleep -Milliseconds 500
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -Headers $headers
        $players = $response.players
        $exactMatch = $players | Where-Object { $_.Name.ToLower() -eq $lower }
        if ($exactMatch) {
          $player = $exactMatch | Select-Object -First 1
          $g = if ([string]::IsNullOrEmpty($player.GuildName)) { "None" } else { $player.GuildName }
          $serverDetails += "$srv`:TAKEN($g)"; $anyTaken = $true; $found = $true; break
        }
        $count = @($players).Length
        if ($count -ge 10) { $limitHit = $true }
        $found = $true; break
      } catch {
        $lastErr = $_.Exception.Message
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 1000 }
      }
    }
    if ($found) {
      if ($limitHit) { $serverDetails += "$srv`:UNSURE"; $anyLimit = $true }
      elseif (-not $anyTaken) { $serverDetails += "$srv`:AVAIL" }
    } else { $serverDetails += "$srv`:ERROR($lastErr)" }
  }
  if ($anyTaken) { return [PSCustomObject]@{ Name = $n; Status = "TAKEN"; Guild = $serverDetails -join " | " } }
  elseif ($anyLimit) { return [PSCustomObject]@{ Name = $n; Status = "UNSURE"; Guild = $serverDetails -join " | " } }
  else { return [PSCustomObject]@{ Name = $n; Status = "AVAILABLE"; Guild = $serverDetails -join " | " } }
} catch { return [PSCustomObject]@{ Name = $n; Status = "ERROR"; Guild = $_.Exception.Message } }
'@

foreach ($name in $allNames) {
  $ps = [PowerShell]::Create()
  $ps.RunspacePool = $runspacePool
  $null = $ps.AddScript($scriptText).AddArgument($name).AddArgument($activeServers)
  $jobs += @{ Handle = $ps.BeginInvoke(); PS = $ps; Name = $name }
}

$done = 0
Write-Host ("-" * 75)
Write-Host ("  {0,-20} {1,-50}" -f "NAME", "STATUS")
Write-Host ("-" * 75)
foreach ($job in $jobs) {
  try {
    $result = $job.PS.EndInvoke($job.Handle)
    Show-Result -r $result
    $results += $result
  } catch {
    Write-Host ("  {0,-20} {1,-50}" -f $job.Name, "ERROR: $($_.Exception.Message)") -ForegroundColor Yellow
    $results += [PSCustomObject]@{ Name = $job.Name; Status = "ERROR" }
  }
  $done++
  Write-Progress -Activity "Checking names..." -Status "$done/$total : $($job.Name)" -PercentComplete ($done / $total * 100)
  $job.PS.Dispose()
}

$runspacePool.Dispose()
Write-Progress -Activity "Done" -Completed

Write-Host ("-" * 75)

$availableCount = @($results | Where-Object { $_.Status -eq "AVAILABLE" }).Count
$unsureCount = @($results | Where-Object { $_.Status -eq "UNSURE" }).Count
$takenCount = @($results | Where-Object { $_.Status -eq "TAKEN" }).Count
$errorCount = @($results | Where-Object { $_.Status -eq "ERROR" }).Count
Write-Host ""
Write-Host "Summary: $availableCount available, $unsureCount unsure, $takenCount taken, $errorCount errors" -ForegroundColor $(if ($availableCount -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Gray })
Write-Host "  us=Americas  eu=Europe  asia=Asia  AVAIL=Available  UNSURE=unclear  TAKEN=exists" -ForegroundColor DarkGray

if ($Output) { Stop-Transcript | Out-Null }

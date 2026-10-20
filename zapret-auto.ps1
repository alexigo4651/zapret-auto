<#
.SYNOPSIS
  Keeps Flowseal zapret-discord-youtube up to date and picks the strategy
  that works for YouTube, Discord and your own sites (my-sites.txt).

.DESCRIPTION
  Default run:
    1. If a previous run crashed mid-way, restore the saved service first.
    2. Check GitHub for a newer release; if found, install it into C:\zapret
       (user lists are carried over, the old version is removed on success).
    3. If the release changed, or the current strategy no longer passes the
       checks, try the general*.bat strategies (current one first) and install
       the first one that opens everything, or the best one if none does.

.PARAMETER Force        Reinstall the latest release and re-pick even if nothing changed.
.PARAMETER Repick       Skip the update check and always re-pick the strategy.
.PARAMETER NoUpdate     Never download a new release.
.PARAMETER CheckOnly    Only probe the sites with the current setup and print the result.
.PARAMETER InstallTask  Register a hidden scheduled task (SYSTEM, at boot) that runs this script.
.PARAMETER RemoveTask   Remove that scheduled task.
.PARAMETER RestoreOnly  Roll back an unfinished run and exit.
.PARAMETER EditSites       Open the "my sites" list in Notepad, then apply it (normal run).
.PARAMETER EditExclusions  Open the exclusions list in Notepad, then apply it (normal run).
#>
param(
  [switch]$EditSites,
  [switch]$EditExclusions,
  [switch]$Force,
  [switch]$Repick,
  [switch]$NoUpdate,
  [switch]$CheckOnly,
  [switch]$InstallTask,
  [switch]$RemoveTask,
  [switch]$RestoreOnly   # used by the watchdog: only roll back an unfinished run
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- settings
$InstallDir   = 'C:\zapret'
$StateDir     = 'C:\zapret-auto'
$Repo         = 'Flowseal/zapret-discord-youtube'
$ServiceName  = 'zapret'
$TaskName     = 'zapret-auto'
$ProbeTimeout = 5      # seconds per request; working sites answer in ~1 s
$ProbeRounds  = 2      # a strategy must pass every round; a failed round ends the test early
$ExtraDomains  = @()   # always added to list-general-user.txt, e.g. @('example.com')
$GameProcesses = @()   # do not touch the network while any of these run, e.g. @('cs2', 'Dota2')

$Targets = @(
  @{ Group = 'youtube'; Url = 'https://www.youtube.com' }
  @{ Group = 'youtube'; Url = 'https://i.ytimg.com' }
  @{ Group = 'youtube'; Url = 'https://redirector.googlevideo.com' }
  @{ Group = 'discord'; Url = 'https://discord.com' }
  @{ Group = 'discord'; Url = 'https://gateway.discord.gg' }
  @{ Group = 'discord'; Url = 'https://cdn.discordapp.com' }
  @{ Group = 'control'; Url = 'https://ya.ru' }
)
# Score per group; 'control' has no weight: a strategy that breaks it is never picked.
$GroupWeight = @{ youtube = 10; discord = 10; mysites = 10 }

# Domains the user adds by hand: they go into zapret's list and into the checks.
$SitesFile   = Join-Path $StateDir 'my-sites.txt'
$ManagedFile = Join-Path $StateDir 'managed-domains.txt'   # what this script put into list-general-user.txt
# Domains / IPs zapret must leave alone.
$ExcludeFile          = Join-Path $StateDir 'exclusions.txt'
$ManagedExcludeFile   = Join-Path $StateDir 'managed-exclude.txt'      # ... in list-exclude-user.txt
$ManagedIpExcludeFile = Join-Path $StateDir 'managed-ip-exclude.txt'   # ... in ipset-exclude-user.txt

$RestoreFile = Join-Path $StateDir 'restore.json'
$StateFile   = Join-Path $StateDir 'state.json'
$LogFile     = Join-Path $StateDir 'zapret-auto.log'

# ---------------------------------------------------------------- helpers
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Log([string]$msg, [string]$color = 'Gray') {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line -ForegroundColor $color
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Read-Json($path) {
  if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null }
}

function Write-Json($path, $obj) {
  $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Get-LocalVersion {
  $bat = Join-Path $InstallDir 'service.bat'
  if (-not (Test-Path $bat)) { return $null }
  $m = Select-String -Path $bat -Pattern 'LOCAL_VERSION=([\d\.]+)' | Select-Object -First 1
  if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

function Get-LatestRelease {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 30 -UseBasicParsing
  $zip = $r.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
  if (-not $zip) { throw "Release $($r.tag_name) has no .zip asset" }
  [pscustomobject]@{ Version = $r.tag_name.TrimStart('v'); Url = $zip.browser_download_url; Name = $zip.name }
}

function Test-Newer([string]$latest, [string]$local) {
  if (-not $local) { return $true }
  try { return ([version]$latest) -gt ([version]$local) } catch { return $latest -ne $local }
}

# Read from the registry: Win32_Service.PathName comes back empty for the
# very long (4000+ chars) zapret command lines.
function Get-ServiceBinPath {
  try {
    (Get-ItemProperty "HKLM:\System\CurrentControlSet\Services\$ServiceName" -Name 'ImagePath' -ErrorAction Stop).ImagePath
  } catch { $null }
}

function Get-ServiceStrategy {
  try {
    (Get-ItemProperty "HKLM:\System\CurrentControlSet\Services\$ServiceName" -Name 'zapret-discord-youtube' -ErrorAction Stop).'zapret-discord-youtube'
  } catch { $null }
}

# Stops the service, any stray winws and the WinDivert driver so files in
# C:\zapret\bin are no longer locked.
function Stop-Zapret {
  if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
  }
  Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($drv in 'WinDivert', 'WinDivert14') {
    & sc.exe stop $drv 2>&1 | Out-Null
  }
  Start-Sleep -Seconds 2
}

function Remove-ZapretService {
  if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { return }
  & sc.exe delete $ServiceName | Out-Null
  # The SCM keeps the service "marked for deletion" while handles are open.
  for ($i = 0; $i -lt 20 -and (Get-Service $ServiceName -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    throw "Service '$ServiceName' is stuck in 'marked for deletion' (close services.msc and retry)"
  }
}

function Install-ZapretService([string]$binPath, [string]$strategy) {
  Remove-ZapretService
  New-Service -Name $ServiceName -BinaryPathName $binPath -DisplayName 'zapret' -StartupType Automatic | Out-Null
  & sc.exe description $ServiceName 'Zapret DPI bypass software' | Out-Null
  if ($strategy) {
    Set-ItemProperty "HKLM:\System\CurrentControlSet\Services\$ServiceName" -Name 'zapret-discord-youtube' -Value $strategy
  }
  Start-Service $ServiceName
}

# True once every 'control' site opens. Used to tell "no internet" (network
# drop, wake from sleep, boot) from "the strategy broke something".
function Wait-Internet([int]$seconds) {
  $urls = @($Targets | Where-Object { $_.Group -eq 'control' } | ForEach-Object { $_.Url })
  $deadline = (Get-Date).AddSeconds($seconds)
  while ($true) {
    $down = $urls | Where-Object { & curl.exe --noproxy '*' -s -o NUL -m 5 $_; $LASTEXITCODE -ne 0 }
    if (-not $down) { return $true }
    if ((Get-Date) -ge $deadline) { return $false }
    Start-Sleep -Seconds 5
  }
}

# Other DPI-bypass tools (another zapret copy, GoodbyeDPI) fight over the same
# WinDivert driver and make every strategy test fail. Their services are only
# disabled (reversible), not deleted; stray processes are killed.
function Disable-OtherBypass {
  $ourBin = "$InstallDir\bin\"
  foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
    $name = $key.PSChildName
    $img = (Get-ItemProperty $key.PSPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if (-not $img) { continue }

    if ($name -in 'WinDivert', 'WinDivert14') {
      # A driver registered from another folder breaks winws if that folder is gone.
      if ($img -notlike "*$ourBin*") {
        & sc.exe stop $name 2>&1 | Out-Null
        & sc.exe delete $name 2>&1 | Out-Null
        Log "Removed $name driver registration from another folder ($img); winws will register ours" 'Yellow'
      }
      continue
    }
    if ($img -notmatch 'winws\.exe|goodbyedpi\.exe|nfqws') { continue }
    if ($name -eq $ServiceName) { continue }   # ours; replaced on install if it points elsewhere

    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if ($svc -and ($svc.Status -ne 'Stopped' -or $svc.StartType -ne 'Disabled')) {
      Stop-Service $name -Force -ErrorAction SilentlyContinue
      Set-Service $name -StartupType Disabled
      Log "Disabled other DPI-bypass service '$name' (was $($svc.StartType)): $($img.Substring(0, [Math]::Min(120, $img.Length)))" 'Yellow'
    }
  }

  $ourPid = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).ProcessId
  $procs = Get-CimInstance Win32_Process -Filter "Name='winws.exe' OR Name='goodbyedpi.exe'" -ErrorAction SilentlyContinue
  foreach ($p in $procs) {
    if ($p.ProcessId -eq $ourPid) { continue }
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Log "Stopped other DPI-bypass process $($p.Name) ($($p.ExecutablePath))" 'Yellow'
  }
}

# Strategies with "--dpi-desync-fooling=ts" need TCP timestamps (service.bat does the same).
function Enable-TcpTimestamps {
  $out = & netsh interface tcp show global
  if (-not ($out | Select-String -Pattern 'timestamps.*enabled' -Quiet)) {
    & netsh interface tcp set global timestamps=enabled | Out-Null
  }
}

function Get-GameFilter([string]$dir) {
  $tcp = '12'; $udp = '12'   # "12" is the placeholder service.bat uses when the filter is off
  $flag = Join-Path $dir 'utils\game_filter.enabled'
  if (Test-Path $flag) {
    $mode = 'all'; $tcpRange = '1024-65535'; $udpRange = '1024-65535'
    foreach ($line in Get-Content $flag) {
      $k, $v = $line -split '=', 2
      switch ($k.Trim().ToLower()) {
        'mode' { $mode = $v.Trim().ToLower() }
        'all'  { $mode = 'all' }
        'tcp'  { if ($v) { $tcpRange = $v.Trim() } else { $mode = 'tcp' } }
        'udp'  { if ($v) { $udpRange = $v.Trim() } else { $mode = 'udp' } }
      }
    }
    if ($mode -in 'all', 'tcp') { $tcp = $tcpRange }
    if ($mode -in 'all', 'udp') { $udp = $udpRange }
  }
  @{ TCP = $tcp; UDP = $udp }
}

# Extracts winws.exe arguments from a strategy .bat and expands its variables.
function Get-StrategyArgs([string]$batPath, [string]$dir) {
  $lines = Get-Content $batPath
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'winws\.exe"') { $start = $i; break } }
  if ($start -lt 0) { return $null }

  $text = ($lines[$start] -split 'winws\.exe"', 2)[1]
  $i = $start
  while ($text.TrimEnd().EndsWith('^') -and $i + 1 -lt $lines.Count) {
    $text = $text.TrimEnd().TrimEnd('^') + ' '
    $i++
    $text += $lines[$i].Trim()
  }

  $gf = Get-GameFilter $dir
  $text = $text.Replace('%BIN%', "$dir\bin\").Replace('%LISTS%', "$dir\lists\")
  $text = $text.Replace('%GameFilterTCP%', $gf.TCP).Replace('%GameFilterUDP%', $gf.UDP).Replace('%GameFilter%', $gf.TCP)
  if ($text -match '%\w+%') { return $null }   # unknown variable: skip this strategy
  ($text -replace '\s+', ' ').Trim()
}

function Get-Strategies([string]$dir) {
  Get-ChildItem $dir -Filter 'general*.bat' |
    Sort-Object { [regex]::Replace($_.BaseName, '\d+', { $args[0].Value.PadLeft(4, '0') }) } |
    ForEach-Object {
      $a = Get-StrategyArgs $_.FullName $dir
      if ($a) { [pscustomobject]@{ Name = $_.BaseName; Args = $a } }
      else { Log "  $($_.BaseName): could not read winws arguments, skipped" 'DarkGray' }
    }
}

# Requests every target in parallel, bypassing the system proxy (VPN client),
# so only zapret decides whether a site opens. Returns url -> $true/$false.
function Invoke-Probes {
  $curlArgs = @('--noproxy', '*', '-s', '-Z', '--parallel-max', '16', '-m', "$ProbeTimeout",
                '-w', "%{url} %{http_code} %{exitcode}`n")
  foreach ($t in $Targets) { $curlArgs += @('-o', 'NUL', $t.Url) }
  $res = @{}
  foreach ($t in $Targets) { $res[$t.Url] = $false }
  foreach ($line in (& curl.exe @curlArgs 2>$null)) {
    $url, $code, $exit = $line -split ' '
    if ($res.ContainsKey($url)) { $res[$url] = ($exit -eq '0' -and $code -ne '000') }
  }
  $res
}

function Measure-Targets {
  $ok = @{}
  foreach ($t in $Targets) { $ok[$t.Url] = $true }
  for ($r = 0; $r -lt $ProbeRounds; $r++) {
    $res = Invoke-Probes
    foreach ($t in $Targets) { if (-not $res[$t.Url]) { $ok[$t.Url] = $false } }
    # Extra rounds only confirm a full pass; once something failed they cannot help.
    if ($ok.Values -contains $false) { break }
  }

  $score = 0; $parts = @()
  foreach ($g in ($Targets | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    $urls = $Targets | Where-Object { $_.Group -eq $g } | ForEach-Object { $_.Url }
    $pass = @($urls | Where-Object { $ok[$_] }).Count
    $parts += "$g $pass/$($urls.Count)"
    if ($GroupWeight.ContainsKey($g)) { $score += $GroupWeight[$g] * $pass / $urls.Count }
  }
  $controlOk = -not ($Targets | Where-Object { $_.Group -eq 'control' -and -not $ok[$_.Url] })
  $allOk     = -not ($Targets | Where-Object { -not $ok[$_.Url] })
  [pscustomobject]@{ Score = $score; Summary = ($parts -join ', '); ControlOk = $controlOk; AllOk = $allOk }
}

function Test-Strategy($s, [string]$dir) {
  $p = Start-Process -FilePath "$dir\bin\winws.exe" -ArgumentList $s.Args -WorkingDirectory "$dir\bin" -WindowStyle Hidden -PassThru
  try {
    Start-Sleep -Seconds 1
    if ($p.HasExited) { return $null }
    Measure-Targets
  } finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
  }
}

function New-SitesFile {
  @(
    '# Мои сайты для zapret — по одному домену в строке, например:'
    '#   example.com'
    '#   rutracker.org'
    '# Поддомены подхватываются сами (example.com включает www.example.com).'
    '# Строки, которые начинаются с #, — комментарии.'
    '# Сохраните файл (Ctrl+S) и закройте Блокнот: программа добавит сайты в zapret и проверит их.'
    ''
  ) | Set-Content -Path $SitesFile -Encoding UTF8
}

function New-ExcludeFile {
  @(
    '# Исключения: сайты, которые zapret НЕ должен трогать (банки, госуслуги, игры,'
    '# которые под zapret работают хуже). По одному в строке, например:'
    '#   sberbank.ru'
    '#   gosuslugi.ru'
    '#   192.168.1.10      (можно IP-адрес)'
    '#   10.0.0.0/8        (или подсеть)'
    '# Поддомены подхватываются сами. Строки с # — комментарии.'
    '# Сохраните файл (Ctrl+S) и закройте Блокнот: программа применит исключения.'
    ''
  ) | Set-Content -Path $ExcludeFile -Encoding UTF8
}

# Reads a user list and returns clean entries: domains ("https://www.x.com/a" -> "x.com")
# and, if $allowIp, IPv4 addresses / subnets.
function Get-ListEntries([string]$path, [switch]$allowIp) {
  $res = [pscustomobject]@{ Domains = @(); Ips = @() }
  if (-not (Test-Path $path)) { return $res }
  $name = Split-Path $path -Leaf
  $idn = New-Object System.Globalization.IdnMapping
  foreach ($raw in Get-Content $path -Encoding UTF8) {
    $d = ($raw -split '#', 2)[0].Trim().ToLower()
    if (-not $d) { continue }
    if ($allowIp -and $d -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { $res.Ips += $d; continue }
    $d = $d -replace '^[a-z]+://', '' -replace '[/:?].*$', '' -replace '^www\.', ''
    try { $d = $idn.GetAscii($d) } catch { }   # Cyrillic domains (.рф) -> punycode
    if ($d -match '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { $res.Domains += $d }
    else { Log "${name}: '$($raw.Trim())' is not a domain$(if ($allowIp) { ' or IP' }), skipped" 'Yellow' }
  }
  $res.Domains = @($res.Domains | Select-Object -Unique)
  $res.Ips     = @($res.Ips | Select-Object -Unique)
  $res
}

# Fresh releases ship without the *-user.txt lists, but every strategy passes
# them to winws, which exits at once if a list is missing. Create them the
# same way service.bat (load_user_lists) does.
function Initialize-UserLists([string]$dir) {
  $defaults = [ordered]@{
    'ipset-exclude-user.txt' = @('203.0.113.113/32')
    'list-general-user.txt'  = @('# Never leave this file empty', 'domain.example.abc')
    'list-exclude-user.txt'  = @('domain.example.abc')
  }
  foreach ($name in $defaults.Keys) {
    $file = Join-Path $dir "lists\$name"
    if (-not (Test-Path $file)) {
      Set-Content -Path $file -Value $defaults[$name] -Encoding ASCII
      Log "Created lists\$name"
    }
  }
}

# Keeps a zapret list file in sync with $items: adds new ones and removes the
# ones this script added earlier (remembered in $managed) that are no longer
# wanted. Lines typed into the zapret file by hand are never touched.
# Returns $true if the file changed.
function Sync-HostList([string]$file, [string]$managed, [string[]]$items, [string]$placeholder) {
  $items = @($items | Where-Object { $_ })
  $lines = if (Test-Path $file) { @(Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
  $prev  = if (Test-Path $managed) { @(Get-Content $managed) } else { @() }

  $removed = @($lines | Where-Object { $prev -contains $_ -and $items -notcontains $_ })
  $added   = @($items | Where-Object { $lines -notcontains $_ })
  $new     = @($lines | Where-Object { $removed -notcontains $_ }) + $added

  Set-Content -Path $managed -Value $items -Encoding ASCII
  if (-not $added -and -not $removed) { return $false }
  # winws refuses an empty list file, so keep the same placeholder service.bat uses.
  if (-not ($new | Where-Object { -not $_.StartsWith('#') })) { $new += $placeholder }
  Set-Content -Path $file -Value $new -Encoding ASCII
  $name = Split-Path $file -Leaf
  if ($added)   { Log "Added to ${name}: $($added -join ', ')" }
  if ($removed) { Log "Removed from ${name}: $($removed -join ', ')" }
  $true
}

# Saves everything needed to roll back before the network is touched.
function Save-RestorePoint([string]$oldDir) {
  Write-Json $RestoreFile ([pscustomobject]@{
    BinPath  = Get-ServiceBinPath
    Strategy = Get-ServiceStrategy
    OldDir   = $oldDir
    Time     = (Get-Date -Format s)
  })
}

function Restore-Previous {
  $rp = Read-Json $RestoreFile
  if (-not $rp) { return }
  Log 'Restoring the previous zapret setup...' 'Yellow'
  Stop-Zapret
  if ($rp.OldDir -and (Test-Path $rp.OldDir)) {
    if (Test-Path $InstallDir) {
      $failed = "$InstallDir.failed-$(Get-Date -Format yyyyMMdd-HHmmss)"
      Rename-Item $InstallDir $failed
      Log "Unfinished install moved to $failed"
    }
    Rename-Item $rp.OldDir $InstallDir
  }
  if ($rp.BinPath) {
    Install-ZapretService $rp.BinPath $rp.Strategy
    Log "Service restored (strategy: $($rp.Strategy))" 'Yellow'
  }
  Remove-Item $RestoreFile -Force
}

# If this process gets killed while the network is torn down (test winws
# running, service stopped), a hidden watchdog rolls everything back.
function Start-Watchdog {
  $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; " +
         "if (Test-Path '$RestoreFile') { & '$PSCommandPath' -RestoreOnly }"
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`"" | Out-Null
}

function Update-Zapret($release) {
  $tmp = Join-Path $env:TEMP 'zapret-auto'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp $release.Name
  Log "Downloading $($release.Name)..."
  Invoke-WebRequest -Uri $release.Url -OutFile $zip -UseBasicParsing -TimeoutSec 120

  $stage = "$InstallDir.new"
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $stage
  Remove-Item $zip -Force
  # The archive may wrap everything in a single top-level folder.
  $inner = Get-ChildItem $stage
  if (-not (Test-Path "$stage\service.bat") -and $inner.Count -eq 1 -and $inner[0].PSIsContainer) {
    $stage = $inner[0].FullName
  }
  if (-not (Test-Path "$stage\bin\winws.exe")) { throw 'Downloaded archive has no bin\winws.exe' }

  # Carry over user lists and switches.
  if (Test-Path $InstallDir) {
    $keep = @(Get-ChildItem "$InstallDir\lists" -Filter '*-user.txt' -ErrorAction SilentlyContinue)
    $keep += @(Get-ChildItem "$InstallDir\utils" -Filter '*.enabled' -ErrorAction SilentlyContinue)
    foreach ($f in $keep) {
      $rel = $f.FullName.Substring($InstallDir.Length)
      Copy-Item $f.FullName (Join-Path $stage $rel) -Force
    }
  }

  $oldDir = $null
  if (Test-Path $InstallDir) { $oldDir = "$InstallDir.old" }
  Save-RestorePoint $oldDir
  Stop-Zapret
  Remove-ZapretService
  if ($oldDir) {
    if (Test-Path $oldDir) { Remove-Item $oldDir -Recurse -Force }
    Rename-Item $InstallDir $oldDir
  }
  Move-Item $stage $InstallDir
  if (Test-Path "$InstallDir.new") { Remove-Item "$InstallDir.new" -Recurse -Force }
  Log "Installed zapret $($release.Version) into $InstallDir" 'Green'
}

function Select-BestStrategy {
  $current = Get-ServiceStrategy
  $list = @(Get-Strategies $InstallDir)
  if (-not $list) { throw "No strategies found in $InstallDir" }
  # Try the current one first so a tie keeps it and nothing changes needlessly.
  $list = @($list | Where-Object { $_.Name -eq $current }) + @($list | Where-Object { $_.Name -ne $current })

  Log "Testing up to $($list.Count) strategies (at most ~$([int]($list.Count * ($ProbeTimeout + 2) / 60) + 1) min, the internet may blink)..."
  $best = $null
  foreach ($s in $list) {
    $m = Test-Strategy $s $InstallDir
    if (-not $m) { Log ("  {0,-34} winws failed to start" -f $s.Name) 'DarkGray'; continue }
    $color = if ($m.AllOk) { 'Green' } else { 'DarkGray' }
    Log ("  {0,-34} {1}" -f $s.Name, $m.Summary) $color
    if (-not $m.ControlOk) { continue }   # breaks normal sites: never pick it
    if (-not $best -or $m.Score -gt $best.Score) {
      $best = [pscustomobject]@{ Name = $s.Name; Args = $s.Args; Score = $m.Score; Result = $m }
    }
    if ($m.AllOk) { Log "  '$($s.Name)' opens everything: stop searching." 'Green'; break }
  }
  $best
}

function Install-Task {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $copy = Join-Path $StateDir 'zapret-auto.ps1'
  if ($PSCommandPath -ne $copy) { Copy-Item $PSCommandPath $copy -Force }
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$copy`""
  # Give the network a moment to come up after boot.
  $boot = New-ScheduledTaskTrigger -AtStartup
  $boot.Delay = 'PT2M'
  # SYSTEM runs in its own invisible session: no console window, no UAC prompt.
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $boot -Principal $principal -Settings $settings -Force | Out-Null
  Log "Scheduled task '$TaskName' installed (runs $copy as SYSTEM 2 min after boot)" 'Green'
}

# ---------------------------------------------------------------- main
if (-not (Test-Admin)) {
  # Relaunch elevated with the same switches.
  $pass = @()
  foreach ($k in $PSBoundParameters.Keys) { $pass += "-$k" }
  $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($pass -join ' ')"
  $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
  exit $p.ExitCode
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

if ($RemoveTask) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Log "Scheduled task '$TaskName' removed"
  exit 0
}
if ($InstallTask) { Install-Task; exit 0 }

if ($RestoreOnly) {
  Log 'Watchdog: main run was interrupted.' 'Yellow'
  Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Restore-Previous
  exit 0
}

if ($EditSites -or $EditExclusions) {
  if ($EditSites) {
    if (-not (Test-Path $SitesFile)) { New-SitesFile }
    $edit = $SitesFile
  } else {
    if (-not (Test-Path $ExcludeFile)) { New-ExcludeFile }
    $edit = $ExcludeFile
  }
  Start-Process notepad.exe -ArgumentList "`"$edit`""
  Write-Host ''
  Write-Host 'Открылся Блокнот со списком.' -ForegroundColor Cyan
  Write-Host 'Впишите сайты, сохраните (Ctrl+S), закройте Блокнот и нажмите здесь Enter.' -ForegroundColor Cyan
  [void](Read-Host)
}

Log '=== zapret-auto start ==='
$exitCode = 0
try {
  if (Test-Path $RestoreFile) {
    Log 'Previous run did not finish.' 'Yellow'
    Restore-Previous
  }
  Start-Watchdog

  $excl = Get-ListEntries $ExcludeFile -allowIp
  if ($excl.Domains -or $excl.Ips) { Log "Exclusions: $(@($excl.Domains) + @($excl.Ips) -join ', ')" }
  $userSites = @((Get-ListEntries $SitesFile).Domains)
  # An exclusion wins: zapret checks --hostlist-exclude first, so such a site is not bypassed.
  $both = @($userSites | Where-Object { $excl.Domains -contains $_ })
  if ($both) { Log "In both lists, the exclusion wins: $($both -join ', ')" 'Yellow' }
  $userSites = @($userSites | Where-Object { $excl.Domains -notcontains $_ })
  # Built-in checks for excluded sites would always fail and trigger useless re-picks.
  $Targets = @($Targets | Where-Object {
    $h = ([uri]$_.Url).Host
    -not ($excl.Domains | Where-Object { $h -eq $_ -or $h.EndsWith(".$_") })
  })
  foreach ($d in $userSites) { $Targets += @{ Group = 'mysites'; Url = "https://$d" } }
  if ($userSites) { Log "My sites: $($userSites -join ', ')" }

  if ($CheckOnly) {
    $m = Measure-Targets
    Log "Current setup ($(Get-ServiceStrategy)): $($m.Summary)" ($(if ($m.AllOk) { 'Green' } else { 'Yellow' }))
    exit 0
  }

  $game = $GameProcesses | Where-Object { Get-Process $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
  if ($game) {
    Log "$game is running: skipping so the game is not interrupted." 'Yellow'
    exit 0
  }

  Disable-OtherBypass

  if (-not (Wait-Internet 60)) {
    # Even the control site fails: is it the network or zapret itself?
    $svcUp = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
    if ($svcUp) {
      Save-RestorePoint $null
      Stop-Service $ServiceName -Force
    }
    if ($svcUp -and (Wait-Internet 15)) {
      Log 'Normal sites open only with zapret off: the strategy breaks the internet, re-picking.' 'Yellow'
      $Repick = $true
    } else {
      if ($svcUp) { Start-Service $ServiceName }
      Remove-Item $RestoreFile -Force -ErrorAction SilentlyContinue
      Log 'No internet connection: nothing changed, will check on the next run.' 'Yellow'
      exit 0
    }
  }

  $updated = $false
  $local = Get-LocalVersion
  if (-not $NoUpdate -and -not $Repick) {
    try {
      $rel = Get-LatestRelease
      Log "Installed: $(if ($local) { $local } else { 'none' }), latest: $($rel.Version)"
      if ($Force -or (Test-Newer $rel.Version $local)) {
        Update-Zapret $rel
        $updated = $true
      }
    } catch {
      Log "Update check failed: $($_.Exception.Message)" 'Yellow'
    }
  }
  if (-not (Test-Path "$InstallDir\bin\winws.exe")) { throw "zapret is not installed in $InstallDir" }
  Initialize-UserLists $InstallDir
  $lists = "$InstallDir\lists"
  $changed = Sync-HostList "$lists\list-general-user.txt" $ManagedFile (@($ExtraDomains) + $userSites | Select-Object -Unique) 'domain.example.abc'
  $changed = (Sync-HostList "$lists\list-exclude-user.txt" $ManagedExcludeFile $excl.Domains 'domain.example.abc') -or $changed
  $changed = (Sync-HostList "$lists\ipset-exclude-user.txt" $ManagedIpExcludeFile $excl.Ips '203.0.113.113/32') -or $changed
  if ($changed) {
    # Restart so winws reloads the lists before the checks below.
    if ((Get-Service $ServiceName -ErrorAction SilentlyContinue).Status -eq 'Running') {
      Restart-Service $ServiceName -Force
      Start-Sleep -Seconds 2
    }
  }

  $needPick = $updated -or $Repick -or $Force -or -not (Get-ServiceBinPath)
  if (-not $needPick) {
    $m = Measure-Targets
    Log "Current strategy ($(Get-ServiceStrategy)): $($m.Summary)"
    if ($m.AllOk) {
      Log 'Everything works, nothing to change.' 'Green'
    } else {
      Log 'Some sites do not open: re-picking the strategy.' 'Yellow'
      $needPick = $true
    }
  }

  if ($needPick) {
    if (-not (Test-Path $RestoreFile)) { Save-RestorePoint $null }
    Enable-TcpTimestamps
    Stop-Zapret
    $best = Select-BestStrategy
    if (-not $best) { throw 'No strategy keeps normal sites working' }

    $bin = "`"$InstallDir\bin\winws.exe`" $($best.Args)"
    Install-ZapretService $bin $best.Name
    Start-Sleep -Seconds 2
    $check = Measure-Targets
    if (-not $check.ControlOk) { throw "Installed '$($best.Name)' but normal sites stopped opening" }
    Log "Installed strategy '$($best.Name)': $($check.Summary)" 'Green'
    if (-not $check.AllOk) { Log 'No strategy opens every site; the best one is installed. Sites that still fail need a VPN.' 'Yellow' }
  }

  # Success: forget the restore point and drop the previous version.
  Remove-Item $RestoreFile -Force -ErrorAction SilentlyContinue
  if (Test-Path "$InstallDir.old") {
    Remove-Item "$InstallDir.old" -Recurse -Force
    Log 'Old version removed.'
  }
  Write-Json $StateFile ([pscustomobject]@{ Version = Get-LocalVersion; Strategy = Get-ServiceStrategy; Time = (Get-Date -Format s) })
} catch {
  $exitCode = 1
  Log "ERROR: $($_.Exception.Message)" 'Red'
  try { Restore-Previous } catch { Log "Restore failed: $($_.Exception.Message)" 'Red' }
} finally {
  # Never leave a test winws running outside the service.
  $svcPid = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).ProcessId
  Get-Process winws -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $svcPid } | Stop-Process -Force -ErrorAction SilentlyContinue
  Log '=== zapret-auto end ==='
}
exit $exitCode

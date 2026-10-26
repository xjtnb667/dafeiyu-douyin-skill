param(
  [int]$VideoWatchSeconds = 45,
  [string]$Theme = ''
)

# ASCII-only on purpose (PowerShell 5.1 mangles UTF-8 literals without BOM).
# Pass any Chinese keyword via -Theme.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Dy = Join-Path $PSScriptRoot 'douyin.ps1'
$StateDir = Join-Path $root 'state'
$LogDir = Join-Path $StateDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$log = Join-Path $LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')

# Theme resolution: -Theme > config.json theme > config.json themes[0] > 'douyin'
$cfgFile = Join-Path $root 'config.json'
$cfgTheme = ''
if (Test-Path $cfgFile) {
  try {
    $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.theme) { $cfgTheme = [string]$cfg.theme }
    elseif ($cfg.themes) {
      $first = @($cfg.themes) | Where-Object { $_ } | Select-Object -First 1
      if ($first) { $cfgTheme = [string]$first }
    }
  } catch { }
}
if (-not $Theme) { $Theme = if ($cfgTheme) { $cfgTheme } else { 'douyin' } }

function Log([string]$msg) {
  $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function Dy([string]$c, [string]$a = '') { & $Dy -cmd $c -arg $a }

Log ('loop start: watch=' + $VideoWatchSeconds + 's theme=' + $Theme)

$videosSinceCheck = 3
while ($true) {
  try {
    if ($videosSinceCheck -ge 3) {
      $tick = (Dy 'tick') | ConvertFrom-Json
      Log ('tick unread=' + $tick.unread + ' n=' + $tick.n + ' playing=' + $tick.video.playing)
      if ($tick.unread) {
        $dms = (Dy 'dms') | ConvertFrom-Json
        $pending = @($dms | Where-Object { $_.unread -gt 0 })
        $names = ''
        foreach ($p in $pending) { $names = $names + $p.name + '(' + $p.unread + ') ' }
        Log ('pending: ' + $names)
        $pending | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $StateDir 'pending-dms.json') -Encoding UTF8
        Write-Host '>>> AGENT: read state/pending-dms.json then open -> chat -> send'
        Start-Sleep -Seconds 30
        continue
      }
      $w = Dy 'watch' $Theme
      Log ('watch: ' + $w)
      $videosSinceCheck = 0
      Start-Sleep -Seconds $VideoWatchSeconds
      continue
    }
    $videosSinceCheck = $videosSinceCheck + 1
    Start-Sleep -Seconds $VideoWatchSeconds
  }
  catch {
    Log ('ERR: ' + $_.Exception.Message)
    Start-Sleep -Seconds 15
  }
}

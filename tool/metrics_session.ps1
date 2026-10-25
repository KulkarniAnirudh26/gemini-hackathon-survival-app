# Records a metrics session for the Yosemite Survival app over adb, then summarizes it.
#
#   .\tool\metrics_session.ps1                 # Ctrl+C to stop
#   .\tool\metrics_session.ps1 -Serial 65270DLKX001YV -IntervalSec 5
#
# Writes metrics\<timestamp>\:
#   system.csv          every IntervalSec: battery %, current (mA), voltage, temperature, app PSS (MB), app CPU %, GPU busy %
#   turns.jsonl         per-turn app log (STT, Laya, Gemma load / TTFT / decode, first audio, battery, PSS)
#   calibration-*.jsonl router calibration runs, if any
#   batterystats.txt    Android's own per-app power estimate for the session
#   summary.md          p50/p90 latencies, quick-vs-Gemma share, drain, peak memory
#
# For battery drain use wireless adb with the USB cable unplugged: a cable charges the phone.
param(
  [string]$Serial = "",
  [int]$IntervalSec = 5,
  [string]$Package = "com.hackathon.yosemite_survival"
)
$ErrorActionPreference = "Continue"
$adbExe = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path $adbExe)) { $adbExe = "adb" }
function Adb { if ($Serial) { & $adbExe -s $Serial @args } else { & $adbExe @args } }

$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $root "metrics\$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
$csv = Join-Path $out "system.csv"
"time,elapsed_s,battery_pct,current_ma,voltage_mv,temp_c,plugged,app_pss_mb,app_cpu_pct,gpu_busy_pct" | Out-File -Encoding utf8 $csv

$remote = "/sdcard/Android/data/$Package/files/metrics"
Write-Host "Session $stamp -> $out"
Adb shell dumpsys batterystats --reset | Out-Null
Adb shell "rm -f $remote/turns.jsonl" | Out-Null   # only this session's turns
$start = Get-Date

function Sample {
  $b = (Adb shell dumpsys battery) -join "`n"
  $level = if ($b -match "level: (\d+)") { $Matches[1] } else { "" }
  $volt = if ($b -match "voltage: (\d+)") { $Matches[1] } else { "" }
  $temp = if ($b -match "temperature: (\d+)") { [double]$Matches[1] / 10 } else { "" }
  $plugged = if ($b -match "(AC|USB|Wireless) powered: true") { $Matches[1] } else { "no" }
  $cur = (Adb shell cat /sys/class/power_supply/battery/current_now 2>$null) -join ""
  $curMa = if ($cur -match "-?\d+") { [math]::Round([double]$Matches[0] / 1000, 1) } else { "" }
  $procId = ((Adb shell pidof $Package) -join "").Trim()
  $pss = ""; $cpu = ""
  if ($procId) {
    $m = (Adb shell dumpsys meminfo $Package) -join "`n"
    if ($m -match "TOTAL PSS:\s+(\d+)") { $pss = [math]::Round([double]$Matches[1] / 1024, 1) }
    elseif ($m -match "TOTAL\s+(\d+)") { $pss = [math]::Round([double]$Matches[1] / 1024, 1) }
    $t = (Adb shell top -b -n 1 -p $procId) -join "`n"
    $line = ($t -split "`n" | Where-Object { $_ -match "^\s*$procId\s" } | Select-Object -First 1)
    if ($line) { $cols = ($line.Trim() -split "\s+"); if ($cols.Length -ge 9) { $cpu = $cols[8] } }
  }
  $gpu = ((Adb shell "cat /sys/class/misc/mali0/device/utilization 2>/dev/null || cat /sys/kernel/gpu/gpu_busy 2>/dev/null") -join "").Trim()
  $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds)
  "$(Get-Date -Format o),$elapsed,$level,$curMa,$volt,$temp,$plugged,$pss,$cpu,$gpu" | Out-File -Append -Encoding utf8 $csv
  Write-Host ("{0,5}s  battery {1}%  {2} mA  {3}C  PSS {4} MB  CPU {5}%  plugged={6}" -f $elapsed, $level, $curMa, $temp, $pss, $cpu, $plugged)
}

try {
  Write-Host "Sampling every $IntervalSec s. Use the app now. Ctrl+C to stop."
  while ($true) { Sample; Start-Sleep -Seconds $IntervalSec }
}
finally {
  Write-Host "`nCollecting..."
  Adb pull "$remote/." $out 2>$null | Out-Null
  (Adb shell dumpsys batterystats $Package) | Out-File -Encoding utf8 (Join-Path $out "batterystats.txt")
  $py = (Get-Command python -ErrorAction SilentlyContinue).Source
  if ($py) { & $py (Join-Path $PSScriptRoot "metrics_summary.py") $out } else { Write-Host "python not found: skip summary" }
  Write-Host "Saved to $out"
}

# Stop the prompt polish widget.
# Match by command line: ShowInTaskbar=False means MainWindowTitle is empty,
# so title-based lookup can no longer find the instance. Split the pattern so
# this helper's own command line never matches itself.
$killed = 0
$pattern = 'wid' + 'get.ps1'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$pattern*" -and $_.ProcessId -ne $PID } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
  }

if ($killed -gt 0) { Write-Host "[prompt-widget] stopped $killed instance(s)." }
else { Write-Host "[prompt-widget] not running." }

# Exit when average CPU load stays at or below the limit for 3 samples in a row (30 s apart).
param([int]$Limit = 60)
$ok = 0
while ($ok -lt 3) {
  $l = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
  if ($l -le $Limit) { $ok++ } else { $ok = 0 }
  Start-Sleep 30
}
"cpu ok $(Get-Date -Format HH:mm)"

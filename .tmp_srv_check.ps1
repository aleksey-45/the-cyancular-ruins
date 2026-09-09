$all = Get-CimInstance Win32_Process
$folder = 'the-cyancular-ruins'
$names = $all | Where-Object { $_.Name -match 'godot|cyancular' }
$paths = $all | Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -like "*$folder*") }
Write-Output "=== godot/cyancular PROCESSES ==="
if ($names) { $names | Select-Object ProcessId, Name, ExecutablePath, CommandLine | Format-List | Out-String -Width 320 } else { Write-Output "NONE" }
Write-Output "=== netstat UDP/TCP LISTEN (7777/7800+/5555/9999) ==="
netstat -ano | Select-String -Pattern '7777|780[0-9]|:5555|:9999' | Out-String -Width 200

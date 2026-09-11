$all = Get-CimInstance Win32_Process
$folder = 'the-cyancular-ruins'

# 1) Name-based: godot / cyancular / server exes commonly from this project
$names = $all | Where-Object { $_.Name -match 'godot|cyancular|cyancular ruins' }
# 2) Path-based: exe located inside this project folder
$paths = $all | Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -like "*$folder*") }

Write-Output "=== NAME-BASED (godot/cyancular) ==="
if ($names) { $names | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String -Width 300 } else { Write-Output "NONE" }

Write-Output "=== EXE INSIDE PROJECT FOLDER ==="
if ($paths) { $paths | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-String -Width 300 } else { Write-Output "NONE" }

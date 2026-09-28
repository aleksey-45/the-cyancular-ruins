# CyR EasyTier elevation launcher (ASCII only - see AGENTS.md encoding rules).
# Spawned by the game (unelevated). Starts the elevated helper via UAC prompt.
# The game polls the session dir for results; if the user declines UAC, the
# poll times out and the game reports a clear error.
param(
    [Parameter(Mandatory = $true)][string]$HelperPath,
    [Parameter(Mandatory = $true)][string]$SessionDir
)
try {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $HelperPath,
        "-SessionDir", $SessionDir
    )
    exit 0
} catch {
    exit 1
}

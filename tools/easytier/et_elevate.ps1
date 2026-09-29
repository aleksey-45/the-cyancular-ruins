# CyR EasyTier elevation launcher (ASCII only - see AGENTS.md encoding rules).
# Spawned by the game (unelevated). Starts the elevated helper via UAC prompt.
# The game polls the session dir for results; if the user declines UAC, the
# poll times out and the game reports a clear error.
param(
    [Parameter(Mandatory = $true)][string]$HelperPath,
    [Parameter(Mandatory = $true)][string]$SessionDir
)
try {
    # Windows PowerShell 5.1 joins -ArgumentList elements with spaces WITHOUT
    # quoting them. Our paths contain spaces ("The Cyancular Ruins"), so they
    # MUST be embedded in literal double quotes or the elevated powershell
    # receives a truncated script path and exits silently.
    Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $HelperPath),
        "-SessionDir", ('"{0}"' -f $SessionDir)
    )
    exit 0
} catch {
    exit 1
}

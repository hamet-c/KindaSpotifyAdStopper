# SpotifyAdRestarter.ps1
# Watches Spotify's window title. When a song plays, the title is "Artist - Song".
# During an ad it changes to "Advertisement" / "Spotify" / a sponsor name.
# When an ad is detected: kill Spotify, relaunch it, and press the media Play key
# to resume the music (restarting clears the ad).
#
# Run with -TestRestart to do a single restart cycle and report how long it took.

param([switch]$TestRestart)

$PollMs          = 250   # how often to check the window title
$CooldownSeconds = 15    # minimum time between restarts (prevents restart loops)
$PausedTitles    = @('Spotify Free', 'Spotify Premium', 'Spotify Duo', 'Spotify Family')
$LogFile         = Join-Path $PSScriptRoot 'watcher.log'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MediaKey {
    [DllImport("user32.dll")]
    static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    const byte VK_MEDIA_PLAY_PAUSE = 0xB3;
    const uint KEYEVENTF_KEYUP = 0x2;
    public static void PlayPause() {
        keybd_event(VK_MEDIA_PLAY_PAUSE, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MEDIA_PLAY_PAUSE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@

function Write-Log([string]$msg) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Get-SpotifyTitle {
    $p = Get-Process Spotify -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowTitle } | Select-Object -First 1
    if ($p) { return $p.MainWindowTitle }
    return $null
}

function Test-IsAd([string]$title) {
    if (-not $title) { return $false }                 # no window / minimized to tray
    if ($PausedTitles -contains $title) { return $false }  # paused or idle
    if ($title -match ' [-–] ') { return $false } # "Artist - Song" = music playing
    return $true   # "Advertisement", "Spotify", sponsor names, etc.
}

function Restart-Spotify {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Stop-Process -Name Spotify -Force -ErrorAction SilentlyContinue
    # wait only until the processes are actually gone (max 5 s)
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Process Spotify -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }

    Start-Process 'spotify:'   # works for the Microsoft Store version

    # wait for the window to come back
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (Get-SpotifyTitle) { break }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 1000   # brief settle so the app accepts the media key

    # press Play, then watch for the song title; re-press every 3 s if needed
    $deadline  = (Get-Date).AddSeconds(15)
    $nextPress = [DateTime]::MinValue
    while ((Get-Date) -lt $deadline) {
        if ((Get-Date) -ge $nextPress) {
            [MediaKey]::PlayPause()
            $nextPress = (Get-Date).AddSeconds(3)
        }
        $t = Get-SpotifyTitle
        if ($t -and $t -match ' [-–] ') {
            Write-Log ("Playback resumed in {0:n1}s: {1}" -f $sw.Elapsed.TotalSeconds, $t)
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Log "Spotify restarted, but couldn't confirm playback resumed - press play if needed."
}

# keep the log from growing forever
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    Remove-Item $LogFile -Force
}

if ($TestRestart) {
    Write-Log "Manual test restart requested..."
    Restart-Spotify
    exit
}

Write-Log "Spotify ad watcher started (poll every ${PollMs}ms)."
$lastRestart = [DateTime]::MinValue

while ($true) {
    $title = Get-SpotifyTitle
    if ($title -and (Test-IsAd $title) -and ((Get-Date) - $lastRestart).TotalSeconds -gt $CooldownSeconds) {
        Write-Log "Ad detected (title: '$title') - restarting Spotify..."
        Restart-Spotify
        $lastRestart = Get-Date
    }
    Start-Sleep -Milliseconds $PollMs
}

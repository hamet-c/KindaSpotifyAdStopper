# SpotifyAdRestarter.ps1
# Watches Spotify's window title. When a song plays, the title is "Artist - Song".
# During an ad it changes to "Advertisement" / "Spotify" / a sponsor name.
# When an ad is detected: kill Spotify, relaunch it, press Play, and skip to the
# next track to resume the music (restarting clears the ad).
#
# Volume fix: a Spotify restart resets its INTERNAL slider to 100%, which made
# every ad jump your volume back to max. We can't read/set that internal slider
# on free Spotify, but your real loudness is (Windows-mixer % x internal %).
# So before the restart we remember Spotify's Windows-mixer level, and after the
# music resumes we set the mixer back to that same level. The internal slider
# going to 100% no longer matters - the mixer pins your actual loudness.
# This needs no keystrokes and no extra focus stealing.
#
# To change volume: just use the Windows volume mixer (or right-click the speaker
# icon -> Volume mixer -> Spotify). The script tracks whatever you set there.
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
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    const byte VK_MEDIA_PLAY_PAUSE = 0xB3;
    const byte VK_MEDIA_NEXT_TRACK = 0xB0;
    const uint KEYEVENTF_KEYUP = 0x2;
    const int SW_SHOWMINNOACTIVE = 7;
    public static void PlayPause() {
        keybd_event(VK_MEDIA_PLAY_PAUSE, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MEDIA_PLAY_PAUSE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
    public static void NextTrack() {
        keybd_event(VK_MEDIA_NEXT_TRACK, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MEDIA_NEXT_TRACK, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
    // minimize WITHOUT activating, so focus never lands on Spotify
    public static void Minimize(IntPtr hWnd) {
        ShowWindowAsync(hWnd, SW_SHOWMINNOACTIVE);
    }
}
"@

# --- Per-application volume control via Windows Core Audio (WASAPI) ---------
# Lets us read and set Spotify's Windows-mixer volume - the control that pins
# your actual loudness regardless of where Spotify's internal slider lands.
Add-Type @"
using System;
using System.Runtime.InteropServices;

[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"), ComImport]
class MMDeviceEnumerator { }

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int NotImpl1();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
}

[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
    int NotImpl1();
    int NotImpl2();
    int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
}

[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
    int GetCount(out int SessionCount);
    int GetSession(int SessionCount, out IAudioSessionControl Session);
}

[Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl {
    int NotImpl1();
    int GetDisplayName(out IntPtr name);
    int SetDisplayName(string name, ref Guid ctx);
    int GetIconPath(out IntPtr path);
    int SetIconPath(string path, ref Guid ctx);
    int GetGroupingParam(out Guid group);
    int SetGroupingParam(ref Guid group, ref Guid ctx);
    int SetRegisterAudioSessionNotification(IntPtr n);
    int SetUnregisterAudioSessionNotification(IntPtr n);
}

[Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
    int NotImpl1();
    int GetDisplayName(out IntPtr name);
    int SetDisplayName(string name, ref Guid ctx);
    int GetIconPath(out IntPtr path);
    int SetIconPath(string path, ref Guid ctx);
    int GetGroupingParam(out Guid group);
    int SetGroupingParam(ref Guid group, ref Guid ctx);
    int SetRegisterAudioSessionNotification(IntPtr n);
    int SetUnregisterAudioSessionNotification(IntPtr n);
    int GetSessionIdentifier(out IntPtr id);
    int GetSessionInstanceIdentifier(out IntPtr id);
    int GetProcessId(out int pid);
    int IsSystemSoundsSession();
    int SetDuckingPreference(bool optOut);
}

[Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume {
    int SetMasterVolume(float level, ref Guid ctx);
    int GetMasterVolume(out float level);
    int SetMute(bool mute, ref Guid ctx);
    int GetMute(out bool mute);
}

public static class AppVolume {
    static Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
    static Guid empty = Guid.Empty;

    static ISimpleAudioVolume FindSession(string processName) {
        var deviceEnum = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
        IMMDevice dev;
        deviceEnum.GetDefaultAudioEndpoint(0 /*eRender*/, 1 /*eMultimedia*/, out dev);
        object o;
        dev.Activate(ref IID_IAudioSessionManager2, 1, IntPtr.Zero, out o);
        var mgr = (IAudioSessionManager2)o;
        IAudioSessionEnumerator sessions;
        mgr.GetSessionEnumerator(out sessions);
        int count;
        sessions.GetCount(out count);
        for (int i = 0; i < count; i++) {
            IAudioSessionControl ctl;
            sessions.GetSession(i, out ctl);
            var ctl2 = (IAudioSessionControl2)ctl;
            int pid;
            ctl2.GetProcessId(out pid);
            try {
                var proc = System.Diagnostics.Process.GetProcessById(pid);
                if (string.Equals(proc.ProcessName, processName, StringComparison.OrdinalIgnoreCase)) {
                    return (ISimpleAudioVolume)ctl;
                }
            } catch { }
        }
        return null;
    }

    // returns volume 0.0-1.0, or -1 if no session found
    public static float Get(string processName) {
        var vol = FindSession(processName);
        if (vol == null) return -1f;
        float level;
        vol.GetMasterVolume(out level);
        return level;
    }

    // set the app's Windows-mixer volume (0.0-1.0); returns false if no session
    public static bool Set(string processName, float level) {
        var vol = FindSession(processName);
        if (vol == null) return false;
        vol.SetMasterVolume(level, ref empty);
        return true;
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

function Get-SpotifyWindow {
    $p = Get-Process Spotify -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Select-Object -First 1
    if ($p) { return $p.MainWindowHandle }
    return [IntPtr]::Zero
}

function Test-IsAd([string]$title) {
    if (-not $title) { return $false }                 # no window / minimized to tray
    if ($PausedTitles -contains $title) { return $false }  # paused or idle
    if ($title -match ' [-–] ') { return $false } # "Artist - Song" = music playing
    return $true   # "Advertisement", "Spotify", sponsor names, etc.
}

function Restart-Spotify {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # remember which window you were using so we can hand focus back afterwards
    $userWindow = [MediaKey]::GetForegroundWindow()

    # the title of the song the ad interrupted - we want to advance PAST this one
    $interruptedTitle = Get-SpotifyTitle

    # Remember Spotify's Windows-mixer volume. The restart resets Spotify's
    # INTERNAL slider to 100%, but we can't touch that on free Spotify; instead
    # we re-pin the mixer to this value afterwards so your real loudness is the
    # same as before the ad. Default to 100% if no session is readable.
    $savedVolume = [AppVolume]::Get('Spotify')
    if ($savedVolume -ge 0) {
        Write-Log ("Saved Spotify mixer volume: {0:p0}" -f $savedVolume)
    } else {
        $savedVolume = 1.0
    }

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

    # Spotify keeps raising itself to the front for a few seconds while it starts
    # up, so a single minimize loses the race. Keep minimizing it (without
    # activating) and re-asserting your window for ~4s to win the fight.
    $keepDown = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $keepDown) {
        $hwnd = Get-SpotifyWindow
        if ($hwnd -ne [IntPtr]::Zero) { [MediaKey]::Minimize($hwnd) }
        if ($userWindow -ne [IntPtr]::Zero) { [void][MediaKey]::SetForegroundWindow($userWindow) }
        Start-Sleep -Milliseconds 200
    }

    # press Play to get audio going, then skip to the next track so we don't
    # replay the song the ad interrupted. Watch for a NEW song title.
    [MediaKey]::PlayPause()
    Start-Sleep -Milliseconds 500
    [MediaKey]::NextTrack()

    $deadline  = (Get-Date).AddSeconds(15)
    $nextPress = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $t = Get-SpotifyTitle
        if ($t -and $t -match ' [-–] ' -and $t -ne $interruptedTitle) {
            # music is back - re-pin the Windows-mixer volume so the restart's
            # internal-slider reset doesn't change how loud you actually are.
            Start-Sleep -Milliseconds 300   # let the new audio session register
            if ([AppVolume]::Set('Spotify', $savedVolume)) {
                Write-Log ("Restored Spotify mixer volume: {0:p0}" -f $savedVolume)
            }
            Write-Log ("Playback resumed (next track) in {0:n1}s: {1}" -f $sw.Elapsed.TotalSeconds, $t)
            return
        }
        if ((Get-Date) -ge $nextPress) {
            # still on the old song or nothing playing - nudge it forward again
            [MediaKey]::PlayPause()
            Start-Sleep -Milliseconds 300
            [MediaKey]::NextTrack()
            $nextPress = (Get-Date).AddSeconds(3)
        }
        Start-Sleep -Milliseconds 250
    }

    # couldn't confirm a new track, but still try to restore the mixer volume so
    # at least loudness is right even if the track-skip didn't land.
    if ([AppVolume]::Set('Spotify', $savedVolume)) {
        Write-Log ("Restored Spotify mixer volume: {0:p0} (track not confirmed)" -f $savedVolume)
    }
    Write-Log "Spotify restarted, but couldn't confirm a new track started - press next if needed."
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

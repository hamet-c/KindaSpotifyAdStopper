# Spotify Ad Restarter

Watches Spotify's window title. Songs show as `Artist - Song`; ads show as
`Advertisement`, `Spotify`, or a sponsor name. When an ad is detected, the
watcher closes Spotify, reopens it, and presses Play to resume your music —
restarting clears the ad queue, so the music continues with only a few
seconds of silence instead of the full ad break.

## Usage

| File | What it does |
|---|---|
| `Start-AdWatcher.vbs` | Double-click to start the watcher **silently in the background** |
| `Start-AdWatcher-Visible.bat` | Same, but with a console window so you can watch it work |
| `Stop-AdWatcher.bat` | Stops the watcher |
| `watcher.log` | Activity log (created automatically) |

Only run one watcher at a time. Activity is logged to `watcher.log` either way.

## Run automatically at login (optional)

1. Press `Win + R`, type `shell:startup`, press Enter.
2. Right-click `Start-AdWatcher.vbs` → **Show more options** → **Create shortcut**,
   then move the shortcut into the Startup folder that opened.

## Notes & limitations

- **Keep the Spotify window open or minimized to the taskbar.** If Spotify is
  closed to the system tray, Windows hides its window title and ads can't be
  detected.
- There's a gap of roughly 4–6 seconds while Spotify restarts and playback
  resumes — most of that is Spotify's own startup time.
- A 15-second cooldown between restarts prevents restart loops. You can tune
  `$CooldownSeconds` and `$PollMs` at the top of `SpotifyAdRestarter.ps1`.
- Run `SpotifyAdRestarter.ps1 -TestRestart` to do one restart cycle and see
  the timing without waiting for a real ad.
- Detection is heuristic (based on the window title), so a rare ad formatted
  like a song title could slip through.

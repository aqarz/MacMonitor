# MacMonitor

A tiny menu bar + desktop resource monitor for macOS 13+ (Apple Silicon and Intel).

- **Menu bar:** `CPU 12%  RAM 54%`. The menu has Show/Hide Desktop Panel, Lock/Unlock Position, Launch at Login, Add Server…, Servers (each server has Reconnect and Remove), and Quit.
- **Desktop panel:** titled with your Mac's name. It's a light, warm, glassy (Tangerine-style) rounded panel that sits on the desktop layer, behind your windows, on every Space. It shows:
  - CPU total % as an 8-slice ring (slices light up with load), plus a 60-second bar history
  - Memory used / total GB and % (used = active + wired + compressed)
  - One bar per local disk volume: free / total (free means "available for important usage")
  - Network download/upload per second, summed over all non-loopback interfaces
- **Linux servers over SSH (optional):** each server you add gets a compact section under the Mac section. It has a status dot (green = online, orange = connecting, red = error), the load average, a CPU bar, a Memory bar (used = MemTotal − MemAvailable), one bar per real filesystem, and network ↓↑. Nothing is installed on the server.
- When the panel is **locked**, clicks pass through it. When it's **unlocked**, a dashed outline appears and you can drag the panel. Its position is saved.
- One 1-second timer drives the local stats. Disk is sampled every 10 s. It never lists processes. Each SSH server updates its own section every 2 s.

## Requirements
- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`). You don't need the full Xcode.

## Build & run
```bash
cd MacMonitor
chmod +x build_app.sh
./build_app.sh                 # builds release + assembles and ad-hoc signs MacMonitor.app
open MacMonitor.app
```
To install it:
```bash
cp -R MacMonitor.app /Applications/
open /Applications/MacMonitor.app
```

Quick dev run without the bundle (Launch at Login is unavailable in this mode):
```bash
swift build -c release && .build/release/MacMonitor
```

Optional universal binary (this may need the full Xcode instead of only CLT):
```bash
UNIVERSAL=1 ./build_app.sh
```

## Monitoring Linux servers (SSH)
MacMonitor runs one long-lived `/usr/bin/ssh` session per server. That session runs a small POSIX `sh` loop which prints `/proc/stat`, `/proc/meminfo`, `df`, `/proc/net/dev`, and `/proc/loadavg` every 2 seconds. The server only needs `sh`, `df`, `grep`, `head`, `tail`, and `/proc`, so any normal Linux distribution works.

**1. Set up key-based SSH login first.** MacMonitor uses `BatchMode=yes`, so it can't type passwords or key passphrases:
```bash
ssh-keygen -t ed25519            # only if you don't have a key yet
ssh-copy-id user@host            # add -p 2222 for a non-standard port
ssh user@host true               # must succeed without a password prompt
```
A key with a passphrase works if it's loaded in the agent / macOS keychain (`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`).
New host keys are accepted automatically on first connect (`StrictHostKeyChecking=accept-new`). A *changed* host key is refused, and the server shows the error.

**2. Add the server:** choose **Add Server…** in the menu bar menu, then fill in Name (optional, defaults to the host), Host, User, Port (default 22), and an optional identity file such as `~/.ssh/id_ed25519`.
Settings from `~/.ssh/config` still apply (ProxyJump, IdentityFile, and so on). Note that the Port field is always passed as `-p`.

**3. Remove or reconnect:** use **Servers → <name> → Remove / Reconnect**.

Behavior:
- If the connection drops or fails, the section turns red and shows ssh's error, for example `Permission denied (publickey)` or `Connection refused`. MacMonitor then retries after 5 s, 10 s, 30 s, and every 60 s after that. The backoff resets once data arrives.
- A dead link is detected within about 30 s (`ServerAliveInterval=15`, `ServerAliveCountMax=2`).
- CPU % comes from `/proc/stat` deltas. Network sums all interfaces except `lo` and container/virtual links (`veth*`, `docker*`, `br-*`, `virbr*`, …), so container traffic isn't counted twice.
- Disks are real filesystems from `df` (no tmpfs/overlay/squashfs/…). MacMonitor skips `/boot*`, `/snap*`, and `/run*`, and lists each device once. The percentage matches `df`'s Use%.
- Quitting MacMonitor terminates every ssh session.
- The server list is stored as JSON in the user defaults. Reset it with `defaults delete com.tweetso.macmonitor remoteServers`.

## Snapshot debug mode
Render the panel to a PNG (on a sample wallpaper gradient) without screenshots:
```bash
MM_SNAPSHOT=/tmp/panel.png .build/release/MacMonitor   # writes the PNG after ~3 s, then quits
```
Materials can't be captured by `ImageRenderer`, so the snapshot uses a flat translucent white fill instead of the blur.
In this mode no SSH connections are made. Instead, a fake online server named `linux-server` with three filesystems is shown, so you can check the remote layout.

## Launch at login
This uses `SMAppService.mainApp`, which only works from the `.app` bundle. It works best from `/Applications`.
If macOS asks for approval, System Settings → General → Login Items opens automatically.
If it fails, an alert explains why.

## Notes
- The app runs as an accessory app (`LSUIElement`), so it has no Dock icon. Quit it from the menu bar item.
- If Gatekeeper complains after you copy the app from another machine, run `xattr -dr com.apple.quarantine MacMonitor.app`.
- Reset the saved panel position: `defaults delete com.tweetso.macmonitor panelOrigin`.

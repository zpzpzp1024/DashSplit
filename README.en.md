# DashSplit (CarPlay Split-Screen)

A jailbreak tweak (Theos + Objective-C++, injected into SpringBoard) that mounts **up to 8 real apps** on the **CarPlay head-unit display** as draggable, zoomable, closable split-screen panes (e.g. DiDi + AMap navigation side by side). Each pane has its own drag / zoom / close controls, and the whole layout (position, zoom, closed state) is persisted and restored automatically when CarPlay reconnects.

> 中文版：[README.md](README.md)

- **Package**: `zp.dashsplit`
- **Current version**: 0.1.54 ｜ iOS 15.0+ (arm64, Dopamine / palera1n style jailbreaks)
- **Hosting reference**: [carplay-cast](https://github.com/EthanArbuckle/carplay-cast) (Apache-2.0)

---

## Features (0.1.53)

1. **Multi-app split screen**: pick up to 8 apps in Settings → 车载分屏 (saved as a comma-separated `SelectedApps` list). They all appear on the car display once CarPlay connects.
2. **Right controls strip** on every pane, top to bottom:
   - **Top 1/5 (drag zone)**: vertical drag handle — drag to move this pane anywhere (independently of the others).
   - **＋**: zoom in 20% (clamped 0.2×–4×).
   - **－**: zoom out 20%.
   - **⟲ (reset)**: one tap restores the pre-zoom size (1.0×).
   - **× (bottom)**: close the pane.
3. **Capsule restore**: a closed pane becomes a draggable, labeled **capsule button** (app name); tap it to restore the pane.
4. **Layout persistence**: drag offsets (normalized to screen width/height percentages), zoom factors and closed states are saved in real time to the `zp.dashsplit` preferences domain and **restored automatically after a CarPlay reconnect / SpringBoard respring**.
5. **Lock-screen safety policy (0.1.28+)**: the tweak **never enters Live mode while the phone is unlocked** (prevents SpringBoard crashes). Panes are only displayed when the phone is locked — unlock auto-hides, lock auto-restores, and a "请锁屏手机后显示" (lock your phone) hint shows while hidden.
6. **Phone test mode**: test the full hosting pipeline on the phone screen without a car.
7. **Fit modes**: `FitMode` — 0 = aspect-fit (default), 1 = stretch fill.
8. **Auto re-host**: crashed/backgrounded apps are re-hosted automatically, with a health-check fallback.

---

## Head-unit controls

| Action | Where | Behavior |
| --- | --- | --- |
| Drag | **right strip, top 1/5 (drag zone)** | move this pane |
| Zoom in | **right strip ＋** | pane grows 20% (overlaps others; they stay put) |
| Zoom out | **right strip －** | pane shrinks 20% |
| Reset size | **right strip ⟲** | back to pre-zoom size (1.0×) |
| Close | **right strip × (bottom)** | collapse pane into a capsule |
| Restore | **tap the capsule** | show the pane again |
| Move capsule | drag it | reposition |

> Every layout change is persisted immediately and restored on the next CarPlay connect.

---

## Installation

### Offline (.deb)

Download the `dashsplit-deb` artifact (or the rolling `dashsplit-latest` release) from GitHub Actions:

```sh
scp zp.dashsplit_*_iphoneos-arm64.deb root@<iphone-ip>:/var/mobile/
ssh root@<iphone-ip>
/var/jb/usr/bin/dpkg -i /var/mobile/zp.dashsplit_*_iphoneos-arm64.deb
killall -9 SpringBoard
```

> This injects SpringBoard. If you hit a respring loop, disable the tweak in Dopamine and reboot, or delete `/var/jb/Library/MobileSubstrate/DynamicLibraries/DashSplit.dylib`.

### SSH one-shot deploy (recommended)

Install OpenSSH on the device, then use `deploy.ps1` from this repo:

```powershell
./deploy.ps1 -Device 192.168.1.23 -Latest          # install newest release
./deploy.ps1 -Device 192.168.1.23 -Deb .\packages\zp.dashsplit_0.1.54_iphoneos-arm64.deb
./deploy.ps1 -Device 192.168.1.23 -LogOnly -Follow  # follow the log live
```

The script: checks connectivity → `scp` → `dpkg -i` → verifies the dylib landed → `killall -9 SpringBoard` → prints `/var/mobile/Library/Logs/DashSplit.log`.

---

## Configuration

**Recommended: Settings → 车载分屏.** Multi-select the apps to put on screen (max 8), choose the fit mode, toggle phone test mode (`TestOnMainScreen`). Changes take effect after **reconnecting CarPlay**.

Prefs domain: `/var/mobile/Library/Preferences/zp.dashsplit.plist`

```xml
<dict>
    <key>Enabled</key>
    <true/>
    <key>SelectedApps</key>
    <string>com.xiaojukeji.didi,com.autonavi.amap</string>
    <key>FitMode</key>
    <integer>0</integer>
    <key>TestLandscape</key>
    <true/>
</dict>
```

| Key | Description |
| --- | --- |
| `Enabled` | master switch, default on |
| `SelectedApps` | comma-separated bundle IDs (max 8) — the apps on screen |
| `FitMode` | 0 = aspect-fit (default), 1 = stretch fill |
| `TestLandscape` | use landscape coordinates in phone test mode |
| `TestOnMainScreen` | phone test mode toggle |
| `PaneOffsetX0/PaneOffsetY0`… | per-pane drag offset (normalized %, saved/restored automatically) |
| `PaneZoom0`… | per-pane zoom factor (saved/restored automatically) |
| `PaneClosed0`… | per-pane closed state (saved/restored automatically) |

Find a bundle ID (SSH):

```sh
for p in /var/containers/Bundle/Application/*/*.app; do
  echo "$p $(/var/jb/usr/bin/plutil -extract CFBundleIdentifier raw "$p/Info.plist" 2>/dev/null)"
done | grep -i didi   # replace with the app keyword you're looking for
```

---

## Testing without a car (phone test mode)

Enable either way:

1. Create an empty file: `/var/mobile/Library/Preferences/zp.dashsplit.test`
2. Or set `TestOnMainScreen` in the Settings pane / plist.

After a respring, the split-screen panes load straight onto the phone screen — no CarPlay needed. **This mode cannot cover** the car `CADisplay` / `AVExternalDevice` session / car-screen window parts; the hosting pipeline itself is fully verifiable.

---

## Emergency off / troubleshooting

- **Disable entirely**: create `/var/mobile/Library/Preferences/zp.dashsplit.off` (logic is skipped on next launch).
- **Crash marker**: if SpringBoard crashes while hosting, `/var/mobile/Library/Preferences/zp.dashsplit.crashed` is written; the next launch shows UI only (no hosting) and clears the marker — respring once more to resume hosting.
- **Separate scene**: `/var/mobile/Library/Preferences/zp.dashsplit.newscene` (no effect for apps that don't support multi-window).
- **Mode override (debug)**: `/var/mobile/Library/Preferences/zp.dashsplit.mode` — `auto` (default: switch to Live after the app process is up) / `none` (never) / `2` (switch immediately, crashes).

---

## Logging

`/var/mobile/Library/Logs/DashSplit.log` (256 KB rotation), including:

- `--- DashSplit 0.1.54 loaded ---` — tweak loaded
- `probe: screens` — head-unit display detected (`car=1` / `carplay=1`)
- `host: ...` — every step of app hosting
- `ui: pane[0] restored off={...} zoom=... closed=...` — layout restore
- `zoom: pane[1] +0.20 -> 1.40` — zoom events

---

## Building

Requires Theos + iOS SDK 16.5 (as used by CI):

```sh
make package FINALPACKAGE=1
# output: packages/zp.dashsplit_<version>_iphoneos-arm64.deb
```

Pushing to the `main` branch triggers `.github/workflows/build.yml`, which:

1. builds the `.deb` with Theos,
2. uploads the `dashsplit-deb` artifact,
3. updates the rolling `dashsplit-latest` release (for `deploy.ps1 -Latest`).

---

## Version history (summary)

- **0.1.54**: layout reset — **changing the selected apps now automatically wipes** the old per-pane offsets/zooms/closed states, so a new app lineup starts fresh with every pane visible; **phone test mode always opens all panes** (stale closed states from an earlier test session no longer reduce it to a row of capsules); multiple panes start **side by side with a small gap** instead of stacked on top of each other.
- **0.1.53**: controls consolidated — drag, zoom in (＋), zoom out (－), reset (⟲, restores the pre-zoom size) and close (×) now all live in one **right vertical strip** (top 1/5 drag zone, then ＋/－/⟲/×); fixed zoom buttons being unresponsive (the whole strip is now lifted above the hosted app view); fixed black screen after tap-restoring a capsule in phone test mode (test mode skips the lock-screen gate and restores immediately).
- **0.1.52**: UI redesign — the top horizontal drag handle became a **left vertical strip** (top: drag; bottom: ＋/− zoom, long-press reset to 1.0×); the close button became a **right vertical × strip**; independent per-pane zoom (overlaps neighbours); layout (offset/zoom/closed state) **persisted in real time and restored on reconnect**.
- **0.1.49**: on unlock, only hide panes and keep the capsule row — don't mark them closed.
- **0.1.28**: lock-screen safety policy — never enter Live while unlocked (fixes the stable-connection crash).
- **0.1.27**: auto-hide panes on phone unlock (fixes the foreground-consistency assertion crash).
- **0.1.23**: manual hosting start after CarPlay connect (avoids the ~10s scene-settings wave crash).
- **0.1.9**: phone test mode (`TestOnMainScreen`).
- **0.1.7**: Settings pane rebuilt with Swift + JinxPrefs.
- **0.1.1**: pick left/right pane apps in Settings.
- **0.1.0**: standalone repo (renamed from Cockpit).

## Disclaimer

This project uses private APIs and is for research/learning purposes only. Not for commercial use. The author is not responsible for any consequences of using this tweak.
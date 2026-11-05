# DashSplit (CarPlay Split-Screen)

A jailbreak tweak (Theos + Objective-C++, injected into SpringBoard) that mounts **up to 8 real apps** on the **CarPlay head-unit display** as draggable, zoomable, closable split-screen panes (e.g. DiDi + AMap navigation side by side). **Long-press any pane — including black/empty areas and real app content — to select and drag it**; a single controls strip pinned to the **right edge of the screen** (app-name label + continuous zoom slider + reset + close) operates on the currently selected pane without ever covering app content. The whole layout (position, zoom, closed state) is persisted and restored automatically when CarPlay reconnects. The app picker in Settings **pins selected apps to the top** (grouped), so unchecking them is easy.

> 中文版：[README.md](README.md)

- **Package**: `zp.dashsplit`
- **Current version**: 0.1.56 ｜ iOS 15.0+ (arm64, Dopamine / palera1n style jailbreaks)
- **Hosting reference**: [carplay-cast](https://github.com/EthanArbuckle/carplay-cast) (Apache-2.0)

---

## Features (0.1.56)

1. **Multi-app split screen**: pick up to 8 apps in Settings → 车载分屏 (saved as a comma-separated `SelectedApps` list). They all appear on the car display once CarPlay connects; **selected apps are pinned to the top of the picker in their own group** (easy to uncheck). The checked order defines the left-to-right split order — pinning does not change it.
2. **Long-press select + drag**: long-press (0.3 s) anywhere on a pane to select it as the **current pane** (border highlights) and start dragging — **this works on every pixel of the pane**: both black/empty areas and real app content (when you long-press app content, the gesture takes that touch over once recognized); **single taps pass straight through to the app**.
3. **Single right-edge controls strip**, pinned to the right edge of the screen (never overlaps app content), top to bottom:
   - **Current app label**: the name of the selected pane's app.
   - **Vertical continuous zoom slider**: seamlessly zoom the current pane 0.2×–4×, **anchored at the pane's center so it never drifts**; parts that grow beyond the screen are clipped.
   - **⟲ (reset)**: restore the pre-zoom size (1.0×).
   - **× (bottom)**: close the current pane.
4. **Capsule restore**: a closed pane becomes a draggable, labeled **capsule button** (app name); tap it to restore the pane.
5. **Layout persistence**: pane centers (normalized to screen width/height percentages), zoom factors and closed states are saved in real time to the `zp.dashsplit` preferences domain and **restored automatically after a CarPlay reconnect / SpringBoard respring**; **changing the app lineup resets the layout** so the new panes all appear expanded.
6. **Lock-screen safety policy (0.1.28+)**: the tweak **never enters Live mode while the phone is unlocked** (prevents SpringBoard crashes). Panes are only displayed when the phone is locked — unlock auto-hides, lock auto-restores, and a "请锁屏手机后显示" (lock your phone) hint shows while hidden.
7. **Phone test mode**: test the full hosting pipeline on the phone screen without a car (always opens every pane).
8. **Fit modes**: `FitMode` — 0 = aspect-fit (default), 1 = stretch fill.
9. **Auto re-host**: crashed/backgrounded apps are re-hosted automatically, with a health-check fallback.

---

## Head-unit controls

| Action | Where | Behavior |
| --- | --- | --- |
| Select current pane | **long-press anywhere on a pane (0.3 s)** — app content included | border highlights; the right-edge strip now controls it |
| Drag | **long-press, then drag without lifting** — app content included | move the pane; the app doesn't respond while dragging, resumes on release |
| Zoom in/out | **right-edge strip slider** | seamless zoom of the current pane (0.2×–4×, anchored at pane center) |
| Reset size | right-edge strip **⟲** | current pane back to 1.0× |
| Close | right-edge strip **×** | collapse current pane into a capsule |
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
./deploy.ps1 -Device 192.168.1.23 -Deb .\packages\zp.dashsplit_0.1.56_iphoneos-arm64.deb
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
| `PaneCenterX0/PaneCenterY0`… | per-pane center anchor (normalized %, saved/restored automatically) |
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

- `--- DashSplit 0.1.56 loaded ---` — tweak loaded
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

- **0.1.56**: interaction polish — **long-pressing real app content now drags the pane too** (the long-press gesture is also attached to the remote scene view; once recognized the touch is taken over from the app, taps still pass through); the **app picker pins selected apps to the top** in a 「已选择」 (selected) group above 「全部应用」 (all apps), each alphabetical — unchecking is effortless and the split order is unaffected.
- **0.1.55**: interaction redesign — **long-press any pane (0.3 s) to select it as the current pane and drag it** (single taps pass through to the app); per-pane strips removed and replaced by a **single controls strip pinned to the right edge of the screen** (current app label + seamless zoom slider 0.2×–4× + ⟲ reset + × close) that never covers app content; zoom is now **continuous and anchored at the pane's center** (no drift), and panes may grow to 4× with overflow clipped; legacy drag offsets (`PaneOffsetX/Y`) are auto-migrated to center anchors (`PaneCenterX/Y`).
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
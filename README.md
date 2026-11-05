# DashSplit（车载分屏）

Jailbreak tweak（Theos + Objective-C++，注入 SpringBoard）：把 **最多 8 个真实 App** 以可拖拽、可缩放、可关闭的「分屏面板」形式挂载到 **CarPlay 车机屏幕**上（滴滴、高德、导航、音乐等可同时显示）。每个面板自带独立的拖动、缩放、关闭控件，且布局状态（位置、缩放、关闭状态）会持久化，重连 CarPlay 后自动恢复。

> English version: [README.en.md](README.en.md)

- **包名**：`zp.dashsplit`
- **当前版本**：0.1.54 ｜ 兼容 iOS 15.0+（arm64，Dopamine / palera1n 等现代 jailbreak）
- **宿主模式参考**：[carplay-cast](https://github.com/EthanArbuckle/carplay-cast)（Apache-2.0）

---

## 功能特性（0.1.53）

1. **多应用分屏**：在系统设置「车载分屏」里勾选要上车的 App（最多 8 个，逗号分隔保存为 `SelectedApps`），连接 CarPlay 后同时出现在车机上。
2. **右侧控制条**：每个面板右侧有一条竖条，从上到下依次排列：
   - **上 1/5（拖动区）**：竖向拖动手柄，上下/左右拖动可任意移动该面板（独立于其他面板）。
   - **＋**：放大 20%（范围 0.2×～4×）。
   - **－**：缩小 20%。
   - **⟲（重置）**：一键恢复缩放前的大小（1.0×）。
   - **×（最底部）**：关闭该面板。
3. **胶囊恢复**：关闭的面板变成一个带 App 名称的**胶囊按钮**（可拖动），点击即可恢复该面板。
4. **布局持久化**：拖动偏移量（按屏幕宽高归一化的百分比）、缩放比例、关闭状态全部实时保存到 `zp.dashsplit` 偏好域，**重连 CarPlay / 重启 SpringBoard 后自动恢复上次布局**。
5. **锁屏安全策略（0.1.28+）**：手机解锁状态下**绝不**进入 Live 模式（避免 SpringBoard 崩溃）；面板只在手机锁屏时显示。解锁自动隐藏，锁屏后自动恢复；隐藏时车机会显示「请锁屏手机后显示」提示。
6. **手机测试模式**：没有车也能测——无需 CarPlay，直接在手机屏幕上加载分屏面板。
7. **显示模式**：`FitMode` 支持 `等比缩放`（默认，保持 App 原始宽高比）和 `拉伸填满`。
8. **自动重挂**：App 画面被系统回收后自动重新挂载，并有健康检查兜底。

---

## 使用说明（车机端）

| 操作 | 位置 | 行为 |
| --- | --- | --- |
| 拖动 | 面板**右侧控制条上 1/5（拖动区）** | 上下/左右移动该面板 |
| 放大 | 面板**右侧控制条 ＋** | 该面板变大 20%（覆盖其他面板，其他面板不动） |
| 缩小 | 面板**右侧控制条 －** | 该面板变小 20% |
| 恢复尺寸 | 面板**右侧控制条 ⟲** | 该面板恢复缩放前大小（1.0×） |
| 关闭 | 面板**右侧控制条 ×（最底部）** | 收起该面板，变成胶囊 |
| 恢复 | 点击**胶囊** | 该面板恢复显示 |
| 拖动胶囊 | 按住胶囊拖动 | 移动胶囊位置 |

> 布局任何变化都会实时保存；下次连接 CarPlay 时按保存的状态恢复。

---

## 安装

### 离线安装（.deb）

从 GitHub Actions 的 `dashsplit-deb` artifact（或滚动 release `dashsplit-latest`）下载：

```sh
scp zp.dashsplit_*_iphoneos-arm64.deb root@<iphone-ip>:/var/mobile/
ssh root@<iphone-ip>
/var/jb/usr/bin/dpkg -i /var/mobile/zp.dashsplit_*_iphoneos-arm64.deb
killall -9 SpringBoard
```

> 会注入 SpringBoard。如出现无限重启，用 Dopamine 关闭 tweak 注入后重启，或删除 `/var/jb/Library/MobileSubstrate/DynamicLibraries/DashSplit.dylib`。

### SSH 一键部署（推荐）

手机安装 OpenSSH 后，使用仓库内的 `deploy.ps1`：

```powershell
./deploy.ps1 -Device 192.168.1.23 -Latest        # 安装最新 release
./deploy.ps1 -Device 192.168.1.23 -Deb .\packages\zp.dashsplit_0.1.54_iphoneos-arm64.deb
./deploy.ps1 -Device 192.168.1.23 -LogOnly -Follow # 实时跟日志
```

脚本流程：确认连通 → `scp` → `dpkg -i` → 确认 dylib 落地 → `killall -9 SpringBoard` → 打印 `/var/mobile/Library/Logs/DashSplit.log`。

---

## 配置

**推荐：系统设置 → 车载分屏。** 可多选上车的 App（最多 8 个）、选择显示模式（等比缩放 / 拉伸填满）、开启手机测试模式（`TestOnMainScreen`）。修改后**重连一次 CarPlay** 生效。

偏好域：`/var/mobile/Library/Preferences/zp.dashsplit.plist`

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

| Key | 说明 |
| --- | --- |
| `Enabled` | 总开关，默认开 |
| `SelectedApps` | 逗号分隔的 Bundle ID 列表（最多 8 个），即上车的 App |
| `FitMode` | 0 = 等比缩放（默认），1 = 拉伸填满 |
| `TestLandscape` | 手机测试模式是否使用横屏坐标 |
| `TestOnMainScreen` | 手机测试模式开关 |
| `PaneOffsetX0/PaneOffsetY0`… | 每个面板的拖动偏移（归一化百分比，自动保存/恢复） |
| `PaneZoom0`… | 每个面板的缩放比例（自动保存/恢复） |
| `PaneClosed0`… | 每个面板的关闭状态（自动保存/恢复） |

Bundle ID 查询（SSH）：

```sh
for p in /var/containers/Bundle/Application/*/*.app; do
  echo "$p $(/var/jb/usr/bin/plutil -extract CFBundleIdentifier raw "$p/Info.plist" 2>/dev/null)"
done | grep -i didi   # 替换为要查的 App 关键字
```

---

## 没有车机怎么测（手机测试模式）

任选其一开启：

1. 创建空文件：`/var/mobile/Library/Preferences/zp.dashsplit.test`
2. 或在设置面板/plist 中打开 `TestOnMainScreen`

重启 SpringBoard 后，无需 CarPlay，手机屏幕会直接加载分屏面板。**手机测试模式测不到**的是车机 `CADisplay`/`AVExternalDevice` 会话与车机窗口部分，宿主链路本身可以完整验证。

---

## 紧急关闭 / 异常处理

- **完全禁用**：创建 `/var/mobile/Library/Preferences/zp.dashsplit.off`（下次启动不加载逻辑）。
- **崩溃标记**：托管中崩溃会写 `/var/mobile/Library/Preferences/zp.dashsplit.crashed`，下次启动只显示 UI 不托管 App，并自动清除；再 respring 一次即可恢复托管。
- **独立场景**：`/var/mobile/Library/Preferences/zp.dashsplit.newscene`（对不支持多窗口的 App 无效）。
- **模式覆盖（调试）**：`/var/mobile/Library/Preferences/zp.dashsplit.mode`，内容写 `auto`（默认，App 进程起来后再切 Live）/ `none`（永不切）/ `2`（立刻切，会崩）。

---

## 日志

`/var/mobile/Library/Logs/DashSplit.log`（256 KB 自动轮转），包含：

- `--- DashSplit 0.1.54 loaded ---`：tweak 加载
- `probe: screens`：车机屏识别（`car=1` / `carplay=1`）
- `host: ...`：宿主 App 的每一步
- `ui: pane[0] restored off={...} zoom=... closed=...`：布局恢复
- `zoom: pane[1] +0.20 -> 1.40`：缩放事件

---

## 构建

需要 Theos + iOS SDK 16.5（CI 使用）：

```sh
make package FINALPACKAGE=1
# 产物在 packages/zp.dashsplit_<版本>_iphoneos-arm64.deb
```

推送到 `main` 分支后，GitHub Actions（`.github/workflows/build.yml`）自动：

1. 用 Theos 构建 `.deb`；
2. 上传 artifact `dashsplit-deb`；
3. 更新滚动 release `dashsplit-latest`（供 `deploy.ps1 -Latest` 使用）。

---

## 版本记录（摘要）

- **0.1.54**：布局重置——**重新选择应用后自动清空**旧的偏移/缩放/关闭状态，新的 App 组合以全新布局出现，所有面板默认显示；**手机测试模式始终打开所有面板**（不再继承上次测试遗留的「关闭」胶囊状态）；多个面板初始**从左到右并排展开**，不再叠在一起遮挡。
- **0.1.53**：控件整合——拖动、放大（＋）、缩小（－）、重置（⟲，恢复缩放前大小）、关闭（×）全部集中在**右侧竖条**（上 1/5 拖动区 + 依次排列的 ＋/－/⟲/×）；修复缩放按钮点击无响应（整个控制条提到 App 视图之上）；修复手机测试模式点胶囊恢复后黑屏（测试模式跳过锁屏门禁、立即恢复）。
- **0.1.52**：UI 改版——顶部横向拖动手柄改为**左侧竖条**（上：拖动；下：＋/− 缩放，长按恢复 1.0×）；关闭按钮改为**右侧竖条 ×**；每个面板独立缩放（覆盖其他面板）；布局（偏移/缩放/关闭状态）**实时保存并在重连后恢复**。
- **0.1.49**：解锁时只隐藏面板、保留胶囊栏，不置 `closed` 状态。
- **0.1.28**：锁屏安全策略——解锁状态下不进入 Live 模式（修复稳定连接崩溃）。
- **0.1.27**：解锁自动隐藏面板（修复前台一致性断言导致的崩屏）。
- **0.1.23**：连接 CarPlay 后手动开始托管（规避连接后 ~10s 的场景波导致的崩溃）。
- **0.1.9**：手机测试模式（TestOnMainScreen）。
- **0.1.7**：设置面板改用 Swift + JinxPrefs 构建。
- **0.1.1**：设置面板选择左右分屏 App。
- **0.1.0**：独立仓库（原 Cockpit 改名 DashSplit）。

## 免责声明

本项目仅供学习研究使用，使用私有 API；请勿用于商业用途，作者对使用本 tweak 造成的任何后果不承担责任。
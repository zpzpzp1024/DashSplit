# DashSplit（车载分屏）

Jailbreak tweak（Theos + Objective-C++，注入 SpringBoard）：把 **最多 8 个真实 App** 以可拖拽、可缩放、可关闭的「分屏面板」形式挂载到 **CarPlay 车机屏幕**上（滴滴、高德、导航、音乐等可同时显示）。每个面板**外侧右侧一条小工具条**（上＝拖动把手、下＝关闭 ×，紧贴面板外缘、**不遮盖任何 app 区域**）；也可以**长按面板任意处**（黑色空白和 App 内容）选中并拖动。屏幕**右缘一条控制条**（名称标签 + 连续缩放滑杆 + 重置）控制当前面板，缩放拉到最大即可铺满/超出屏幕。布局状态（位置、缩放、关闭状态）会持久化，重连 CarPlay 后自动恢复。设置里的应用选择列表**已选应用置顶**（分组显示），方便随时取消。

> English version: [README.en.md](README.en.md)

- **包名**：`zp.dashsplit`
- **当前版本**：0.1.58 ｜ 兼容 iOS 15.0+（arm64，Dopamine / palera1n 等现代 jailbreak）
- **宿主模式参考**：[carplay-cast](https://github.com/EthanArbuckle/carplay-cast)（Apache-2.0）

---

## 功能特性（0.1.58）

1. **多应用分屏**：在系统设置「车载分屏」里勾选要上车的 App（最多 8 个，逗号分隔保存为 `SelectedApps`），连接 CarPlay 后同时出现在车机上；**已勾选的 App 在列表中置顶分组显示**（方便取消勾选），勾选顺序即分屏从左到右的顺序，置顶不影响分屏顺序。
2. **每面板右侧外部工具条**：每个面板**外侧右侧竖排 2 个按钮**——上：**拖动把手**（按住上下左右拖动该面板）；下：**关闭 ×**（收起面板变胶囊）。工具条紧贴面板外缘、随面板移动/缩放，**不遮盖 app 任何区域**。
3. **长按选中 + 拖动**：**长按面板任意位置 0.3 秒**（黑色空白区、App 内容区都行）也可选中为「当前面板」（边框高亮）并拖动；识别成功后该次触摸不再传给 App，**单击完全透传给 App**。
4. **屏幕右缘控制条**：固定在屏幕最右缘（不透App内容），控制当前面板：
   - **当前 App 名称标签**；
   - **连续缩放滑杆（竖）**：0.2×～上限（**上限动态计算**，拖到最大一定铺满屏幕甚至超屏，App 占比越小上限越大，封顶 12×）；
   - **⟲（重置）**：一键恢复 1.0×。
5. **胶囊恢复**：关闭的面板变成一个带 App 名称的**胶囊按钮**（可拖动），点击即可恢复。
6. **布局持久化**：面板中心、缩放比例、关闭状态实时保存，重连 CarPlay / 重启 SpringBoard 后自动恢复；**重新选择 App 组合时自动重置布局**。
7. **锁屏安全策略（0.1.28+）**：手机解锁状态下**绝不**进入 Live 模式；面板只在手机锁屏时显示。
8. **手机测试模式**：无需 CarPlay，直接在手机屏幕上加载分屏面板（始终打开所有面板）。
9. **显示模式**：`FitMode` 支持 `等比缩放`（默认）和 `拉伸填满`。
10. **自动重挂**：App 画面被系统回收后自动重新挂载，并有健康检查兜底。
11. **手动开始（0.1.58+）**：设置里可开启「手动开始」；开启后连接车机只显示一个「▶ 开始」按钮，点击才开始托管（默认自动开始）。
12. **自动开始防闪烁（0.1.58+）**：自动模式下连接车机后先显示占位，等约 8 秒连接风暴过去再托管，消除「先显示→消失→再显示」的闪烁；被「手机未锁屏」策略推迟的操作（点胶囊/点开始）会显示提示，不再像没反应。

---

## 使用说明（车机端）

| 操作 | 位置 | 行为 |
| --- | --- | --- |
| 拖动 | 面板**外侧右侧工具条上按钮（拖动把手）**，按住拖动 | 上下/左右移动该面板 |
| 选中当前面板 | **长按面板任意位置 0.3 秒**（含 App 内容区） | 该面板边框高亮，右侧控制条开始控制它 |
| 拖动（长按） | **长按面板后不松手拖动**（含 App 内容区） | 移动该面板；拖动期间 App 不响应，松手恢复 |
| 关闭 | 面板**外侧右侧工具条下按钮 ×** | 收起该面板，变成胶囊 |
| 放大/缩小 | 屏幕**右缘控制条滑杆** | 无级缩放当前面板（0.2×～动态上限，拉满铺满/超屏，以面板中心为锚点） |
| 恢复尺寸 | 右缘控制条 **⟲** | 当前面板恢复缩放前大小（1.0×） |
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
./deploy.ps1 -Device 192.168.1.23 -Deb .\packages\zp.dashsplit_0.1.58_iphoneos-arm64.deb
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
| `ManualStart` | 手动开始：连接车机后只显示「开始」按钮，点击才托管（默认自动开始） |
| `SelectedApps` | 逗号分隔的 Bundle ID 列表（最多 8 个），即上车的 App |
| `FitMode` | 0 = 等比缩放（默认），1 = 拉伸填满 |
| `TestLandscape` | 手机测试模式是否使用横屏坐标 |
| `TestOnMainScreen` | 手机测试模式开关 |
| `PaneCenterX0/PaneCenterY0`… | 每个面板的中心锚点（归一化百分比，自动保存/恢复） |
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

- **0.1.58**：控件移到**面板外部右侧工具条**（拖动把手 + 关闭 × 竖排，不遮盖 app 任何区域）——修复点关闭偶发无反应；点胶囊被「手机未锁屏」策略推迟时显示提示「手机解锁中，锁屏后恢复」（不再像没反应）；设置新增**手动开始**开关（连接车机只显示「开始」按钮，点击才托管，默认自动）；自动模式连接车机后延迟约 8 秒再托管，消除「先显示→消失→再显示」闪烁。

- **0.1.57**：控件回归——每个面板**右内侧上下 2 个按钮**：上＝**拖动把手**（按住可拖）、下＝**关闭 ×**（原来的关闭从屏幕右缘控制条移回每个面板）；右缘控制条保留名称 + 连续缩放滑杆 + ⟲ 重置；**缩放滑杆上限改为动态计算**（拉到最大一定铺满屏幕甚至超出，占比小的 App 上限更大，封顶 12×），修复"拉到最大却不满屏"的问题。
- **0.1.56**：交互优化——**长按 App 内容区域也能拖动面板**（长按手势同时挂到远程场景视图上：在 App 画面上长按，识别后该次触摸不再传给 App，拖动面板；单击仍正常点击）；设置里的**应用选择列表已选 App 置顶分组**（「已选择」「全部应用」两组、各自字母序），勾选/取消一目了然，且不影响分屏排列顺序。
- **0.1.55**：交互改版——**长按任意面板 0.3 秒**选中为「当前面板」并拖动（单击透传给 App）；面板自带的控制条全部移除，改为**屏幕右缘一条统一控制条**（当前 App 名称 + 无级缩放滑杆 0.2×～4× + ⟲ 重置 + × 关闭），固定在屏幕右缘、**不侵入 App 内容**；缩放改为**以面板中心为锚点的连续缩放**，放大 4× 超出屏幕自动裁切；旧版拖动偏移（`PaneOffsetX/Y`）自动迁移为中心锚点（`PaneCenterX/Y`）。
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
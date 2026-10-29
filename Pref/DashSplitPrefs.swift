// DashSplit preferences pane — the 车载分屏 page in Settings.
//
// 0.1.8: the app pickers are our own controller pages (one PSButtonCell row
// per app) instead of PSListItemsController detail rows, which crashed
// Settings on open on the target device. Everything here uses the row types
// Reverie's proven pane uses (GroupCell/ToggleCell/ButtonCell machinery via
// JinxPrefs). Selecting an app writes the bundle ID straight into the plist
// file the tweak reads; changes apply the next CarPlay connect.

import Preferences
import UIKit

private let prefsFile = "/var/mobile/Library/Preferences/lilliana.dashsplit.plist"
private let keyEnabled = "Enabled"
private let keyLeft = "HostBundleID"
private let keyRight = "HostBundleID2"
private let keyThird = "HostBundleID3"
private let keyStretchFill = "StretchFill"
private let keySplitMode = "SplitMode"
private let keySplitRatio = "SplitRatio"
private let keySplitRatio2 = "SplitRatio2"
private let keySplitRatio3 = "SplitRatio3"

// Tweak version shown in the settings pane.
private let tweakVersion = "0.1.28"

// Uninstallable system apps: the defaults must exist on every device.
private let defaultLeft = "com.apple.mobiletimer"   // 时钟
private let defaultRight = "com.apple.mobilecal"     // 日历
private let defaultThird = "com.apple.calculator"   // 计算器

private let prefsDomain = "lilliana.dashsplit" as CFString

private func loadPrefs() -> [String: Any] {
    (NSDictionary(contentsOfFile: prefsFile) as? [String: Any]) ?? [:]
}

// Write through cfprefsd so Settings' own preference writes and ours can
// never clobber each other; Synchronize forces the plist file to update.
private func setPref(_ value: Any, forKey key: String) {
    CFPreferencesSetValue(key as CFString, value as CFTypeRef, prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

// Read through cfprefsd (where all writes go) with the file as fallback —
// a file-only read lagged behind cfprefsd's cache and showed stale picks.
private func currentSelection(_ key: String, _ fallback: String) -> String {
    if let value = CFPreferencesCopyAppValue(key as CFString, prefsDomain) as? String, !value.isEmpty {
        return value
    }
    if let value = loadPrefs()[key] as? String, !value.isEmpty { return value }
    return fallback
}

private func currentSplitMode() -> Int {
    if let value = CFPreferencesCopyAppValue(keySplitMode as CFString, prefsDomain) as? Int {
        return value == 3 ? 3 : 2
    }
    if let value = loadPrefs()[keySplitMode] as? Int {
        return value == 3 ? 3 : 2
    }
    return 2
}

private func currentRatio(_ key: String, _ fallback: Int) -> Int {
    if let value = CFPreferencesCopyAppValue(key as CFString, prefsDomain) as? Int, value > 0 {
        return value
    }
    if let value = loadPrefs()[key] as? Int, value > 0 {
        return value
    }
    return fallback
}

private func ratioDescription() -> String {
    let mode = currentSplitMode()
    if mode == 2 {
        let r1 = currentRatio(keySplitRatio, 0)
        if r1 > 0 {
            let r2 = currentRatio(keySplitRatio2, 0)
            if r2 > 0 {
                return "\(r1):\(r2)"
            }
            return "\(r1):\(100 - r1)"
        }
        return "1:2 (默认)"
    } else {
        let r1 = currentRatio(keySplitRatio, 0)
        let r2 = currentRatio(keySplitRatio2, 0)
        let r3 = currentRatio(keySplitRatio3, 0)
        if r1 > 0 || r2 > 0 || r3 > 0 {
            return "\(r1 > 0 ? r1 : 1):\(r2 > 0 ? r2 : 1):\(r3 > 0 ? r3 : 1)"
        }
        return "1:1:1 (默认)"
    }
}

private func appName(for bundleID: String, apps: [[String: String]]) -> String {
    apps.first(where: { $0["id"] == bundleID })?["name"] ?? bundleID
}

// Every installed app the user could reasonably pick: user apps plus system
// apps (时钟/计算器/…), internals filtered out. LSApplicationWorkspace lives
// in the private MobileCoreServices framework, loaded on demand.
private func installedApps() -> [[String: String]] {
    if let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MobileCoreServices.framework"), !bundle.isLoaded {
        bundle.load()
    }
    guard
        let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
        workspaceClass.responds(to: NSSelectorFromString("defaultWorkspace"))
    else { return [] }
    guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
    else { return [] }
    guard workspace.responds(to: NSSelectorFromString("allInstalledApplications")),
          let proxies = workspace.perform(NSSelectorFromString("allInstalledApplications"))?.takeUnretainedValue() as? [NSObject]
    else { return [] }

    var apps: [[String: String]] = []
    var seen = Set<String>()
    for proxy in proxies {
        guard let name = proxy.value(forKey: "localizedName") as? String, !name.isEmpty,
              let bundleID = proxy.value(forKey: "bundleIdentifier") as? String, !bundleID.isEmpty
        else { continue }
        if seen.contains(bundleID) { continue }

        // applicationType: NSString ("System"/"User"/…) on old iOS,
        // NSNumber enum (0=User, 1=System, 2=Internal…) on new.
        let rawType = proxy.value(forKey: "applicationType")
        if let type = rawType as? String {
            if type != "System" && type != "User" { continue }
        } else if let type = rawType as? NSNumber {
            let raw = type.intValue
            if raw != 0 && raw != 1 { continue }
        }

        seen.insert(bundleID)
        apps.append(["name": name, "id": bundleID])
    }
    apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
    return apps
}

// Per-row tap target for the picker list. PSButtonCell invokes the action
// on the specifier's target; a dedicated object per row carries the bundle
// ID without touching selector arity (Reverie's 0-arg button pattern).
private final class AppRowTarget: NSObject {
    let bundleID: String
    let paneKey: String
    weak var picker: AppPickerController?

    init(bundleID: String, paneKey: String, picker: AppPickerController?) {
        self.bundleID = bundleID
        self.paneKey = paneKey
        self.picker = picker
    }

    @objc func selectApp() {
        setPref(bundleID, forKey: paneKey)
        NSLog("[DashSplitPref] set %@ = %@", paneKey, bundleID)
        // Refresh the parent pane's rows deterministically — relying on
        // viewWillAppear alone left the row titles stale after a pick.
        if let nav = picker?.navigationController, nav.viewControllers.count >= 2,
           let parent = nav.viewControllers[nav.viewControllers.count - 2] as? DashSplitPrefListController {
            parent.refreshPane()
        }
        picker?.navigationController?.popViewController(animated: true)
    }
}

class AppPickerController: PSListController {
    var paneKey: String { "" }
    var paneTitle: String { "" }
    var fallbackID: String { "" }

    private var rowTargets: [AppRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = paneTitle
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let current = currentSelection(paneKey, fallbackID)
            let apps = installedApps()
            rowTargets = []

            var specifiers = NSMutableArray()
            // Current selection first, then everything else.
            specifiers.add(PSSpecifier.emptyGroup())
            if let currentRow = buttonRow(name: "当前:" + appName(for: current, apps: apps), bundleID: current) {
                specifiers.add(currentRow)
            }
            for app in apps where app["id"] != current {
                if let row = buttonRow(name: app["name"] ?? "", bundleID: app["id"] ?? "") {
                    specifiers.add(row)
                }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    private func buttonRow(name: String, bundleID: String) -> PSSpecifier? {
        let target = AppRowTarget(bundleID: bundleID, paneKey: paneKey, picker: self)
        rowTargets.append(target)

        let row = PSSpecifier.preferenceSpecifierNamed(
            name,
            target: target,
            set: nil,
            get: nil,
            detail: nil,
            cell: .buttonCell,
            edit: nil
        )
        row?.buttonAction = #selector(AppRowTarget.selectApp)
        return row
    }
}

@objc(DashSplitLeftAppPicker)
final class DashSplitLeftAppPicker: AppPickerController {
    override var paneKey: String { keyLeft }
    override var paneTitle: String { "第1屏应用" }
    override var fallbackID: String { defaultLeft }
}

@objc(DashSplitRightAppPicker)
final class DashSplitRightAppPicker: AppPickerController {
    override var paneKey: String { keyRight }
    override var paneTitle: String { "第2屏应用" }
    override var fallbackID: String { defaultRight }
}

@objc(DashSplitThirdAppPicker)
final class DashSplitThirdAppPicker: AppPickerController {
    override var paneKey: String { keyThird }
    override var paneTitle: String { "第3屏应用" }
    override var fallbackID: String { defaultThird }
}

// Split mode picker: a simple list to choose 2-way or 3-way split.
private final class SplitModeRowTarget: NSObject {
    let mode: Int
    weak var picker: SplitModePickerController?

    init(mode: Int, picker: SplitModePickerController?) {
        self.mode = mode
        self.picker = picker
    }

    @objc func selectMode() {
        setPref(mode, forKey: keySplitMode)
        NSLog("[DashSplitPref] set SplitMode = %d", mode)
        if let nav = picker?.navigationController, nav.viewControllers.count >= 2,
           let parent = nav.viewControllers[nav.viewControllers.count - 2] as? DashSplitPrefListController {
            parent.refreshPane()
        }
        picker?.navigationController?.popViewController(animated: true)
    }
}

class SplitModePickerController: PSListController {
    private var rowTargets: [SplitModeRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "分屏模式"
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let current = currentSplitMode()
            rowTargets = []

            var specifiers = NSMutableArray()
            specifiers.add(PSSpecifier.emptyGroup())

            let modes: [(Int, String)] = [(2, "2分屏"), (3, "3分屏")]
            for (mode, name) in modes {
                let title = mode == current ? "当前: \(name)" : name
                let target = SplitModeRowTarget(mode: mode, picker: self)
                rowTargets.append(target)
                let row = PSSpecifier.preferenceSpecifierNamed(
                    title,
                    target: target,
                    set: nil,
                    get: nil,
                    detail: nil,
                    cell: .buttonCell,
                    edit: nil
                )
                row?.buttonAction = #selector(SplitModeRowTarget.selectMode)
                if let row = row { specifiers.add(row) }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }
}

@objc(DashSplitSplitModePicker)
final class DashSplitSplitModePicker: SplitModePickerController {}

// Respring target: the "应用设置" button asks for confirmation, then
// kills SpringBoard so all preference changes take effect immediately.
private final class RespringTarget: NSObject {
    weak var controller: PSListController?

    init(controller: PSListController?) {
        self.controller = controller
    }

    @objc func respringTapped() {
        guard let vc = controller else { return }
        let alert = UIAlertController(
            title: "应用设置",
            message: "确定要重启 SpringBoard 吗?\n重启后所有更改将立即生效。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重启", style: .destructive, handler: { _ in
            NSLog("[DashSplitPref] respring triggered by user")
            // killall -9 SpringBoard via posix_spawn — the tweak reloads on the next boot.
            // On rootless jailbreaks the binary lives at /var/jb/usr/bin/killall.
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("killall"),
                strdup("-9"),
                strdup("SpringBoard"),
                nil
            ]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            let paths = ["/var/jb/usr/bin/killall", "/usr/bin/killall"]
            for path in paths {
                if posix_spawn(&pid, path, nil, nil, argv, nil) == 0 {
                    NSLog("[DashSplitPref] respring spawned pid %d via %s", pid, path)
                    break
                }
            }
        }))
        vc.present(alert, animated: true)
    }
}

@objc(DashSplitPrefListController)
final class DashSplitPrefListController: PSListController {
    // Kept alive so the button's target is not deallocated.
    private var respringTarget: RespringTarget?

    override func viewDidLoad() {
        super.viewDidLoad()
        Metadata.package = "lilliana.dashsplit"
        Metadata.tweakName = "车载分屏"
        Metadata.developer = "zpzpzp"
        title = "车载分屏"
    }

    // A link row per pane that shows the current pick in its title.
    private func paneRow(_ title: String, current: String, detail: AnyClass) -> PSSpecifier? {
        let apps = installedApps()
        let row = PSSpecifier.preferenceSpecifierNamed(
            "\(title):\(appName(for: current, apps: apps))",
            target: self,
            set: nil,
            get: nil,
            detail: detail,
            cell: .linkCell,
            edit: nil
        )
        return row
    }

    // A simple link row that pushes a detail controller — used for the split
    // mode picker where there is no "current app" to show.
    private func linkRow(_ title: String, detail: AnyClass) -> PSSpecifier? {
        let row = PSSpecifier.preferenceSpecifierNamed(
            title,
            target: self,
            set: nil,
            get: nil,
            detail: detail,
            cell: .linkCell,
            edit: nil
        )
        return row
    }

    override var specifiers: NSMutableArray? {
        get {
            // Cells bake Metadata.package into their "defaults" domain —
            // set it before any cell is built, not only in viewDidLoad
            // (specifiers can be requested before viewDidLoad runs; an
            // empty package here made the toggle write to a broken domain).
            Metadata.package = "lilliana.dashsplit"
            Metadata.tweakName = "车载分屏"
            Metadata.developer = "zpzpzp"

            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            var specifiers = NSMutableArray()
            SpecifierFactory.add([
                GroupCell(
                    name: "通用",
                    footerText: "启用后,连接 CarPlay 时会在车机屏幕上左右分屏显示下面选择的两个 App。"
                ),
                ToggleCell(name: "启用分屏", key: keyEnabled, defaultValue: true)
            ], to: &specifiers, in: self)

            // Split mode selector row.
            let modeName = currentSplitMode() == 3 ? "3分屏" : "2分屏"
            if let modeRow = linkRow("分屏模式:\(modeName)", detail: DashSplitSplitModePicker.self) {
                specifiers.add(modeRow)
            }

            SpecifierFactory.add([
                GroupCell(
                    name: "分屏应用",
                    footerText: "点进去选择 App;更改后重新连接 CarPlay 生效;同一个 App 只投第一个出现的区域。"
                )
            ], to: &specifiers, in: self)
            if let left = paneRow("第1屏应用", current: currentSelection(keyLeft, defaultLeft), detail: DashSplitLeftAppPicker.self) {
                specifiers.add(left)
            }
            if let right = paneRow("第2屏应用", current: currentSelection(keyRight, defaultRight), detail: DashSplitRightAppPicker.self) {
                specifiers.add(right)
            }
            // Only show the third pane picker in 3-split mode.
            if currentSplitMode() == 3 {
                if let third = paneRow("第3屏应用", current: currentSelection(keyThird, defaultThird), detail: DashSplitThirdAppPicker.self) {
                    specifiers.add(third)
                }
            }

            SpecifierFactory.add([
                GroupCell(
                    name: "分屏比例",
                    footerText: "拖动滑块设置每屏占比(1-99)。2分屏只需设第1屏,第2屏自动取剩余;3分屏可分别设3个屏。不设则用默认(2分屏1:2,3分屏1:1:1)。更改后重启 SpringBoard 生效。"
                ),
                SliderCell(name: "第1屏占比", key: keySplitRatio, defaultValue: 0, range: 1..<100)
            ], to: &specifiers, in: self)
            if currentSplitMode() == 3 {
                SpecifierFactory.add([
                    SliderCell(name: "第2屏占比", key: keySplitRatio2, defaultValue: 0, range: 1..<100),
                    SliderCell(name: "第3屏占比", key: keySplitRatio3, defaultValue: 0, range: 1..<100)
                ], to: &specifiers, in: self)
            } else {
                SpecifierFactory.add([
                    SliderCell(name: "第2屏占比", key: keySplitRatio2, defaultValue: 0, range: 1..<100)
                ], to: &specifiers, in: self)
            }

            SpecifierFactory.add([
                GroupCell(
                    name: "显示",
                    footerText: "开启后 App 画面会拉伸填满整个分屏区域(不保持原始宽高比);关闭则等比缩小居中显示,两侧可能留有空白。更改后重新连接 CarPlay 生效。"
                ),
                ToggleCell(name: "拉伸填满", key: keyStretchFill, defaultValue: false)
            ], to: &specifiers, in: self)

            SpecifierFactory.add([
                GroupCell(
                    name: "测试",
                    footerText: "不连 CarPlay,直接在手机屏幕上模拟车机横屏布局预览。开启后几秒内出现,关闭后几秒内消失。"
                ),
                ToggleCell(name: "手机测试模式", key: "TestOnMainScreen", defaultValue: false)
            ], to: &specifiers, in: self)

            // Respring button — applies all changes immediately.
            respringTarget = RespringTarget(controller: self)
            SpecifierFactory.add([
                GroupCell(
                    name: "应用",
                    footerText: "更改以上设置后,点击下方按钮重启 SpringBoard 以立即生效。"
                )
            ], to: &specifiers, in: self)
            if let btn = PSSpecifier.preferenceSpecifierNamed(
                "应用设置",
                target: respringTarget!,
                set: nil,
                get: nil,
                detail: nil,
                cell: .buttonCell,
                edit: nil
            ) {
                btn.buttonAction = #selector(RespringTarget.respringTapped)
                specifiers.add(btn)
            }

            // Version display at the bottom.
            SpecifierFactory.add([
                GroupCell(
                    name: "关于",
                    footerText: "DashSplit \(tweakVersion) — 当前分屏比例 \(ratioDescription())"
                )
            ], to: &specifiers, in: self)
            if let versionRow = PSSpecifier.preferenceSpecifierNamed(
                "版本:\(tweakVersion)",
                target: self,
                set: nil,
                get: nil,
                detail: nil,
                cell: .linkCell,
                edit: nil
            ) {
                specifiers.add(versionRow)
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    // Drop the cached specifiers and rebuild, so the pane rows pick up the
    // current selections in their titles.
    @objc func refreshPane() {
        setValue(nil, forKey: "_specifiers")
        perform(NSSelectorFromString("reloadSpecifiers"))
    }

    // Refresh the pane rows (they show the current pick in their titles)
    // when coming back from a picker page.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPane()
    }
}
